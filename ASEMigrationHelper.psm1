$ErrorActionPreference = "Stop"
$global:Kubectl = ""

function Copy-PVCData
{
    [CmdletBinding()]
    Param
    (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Namespace,

        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetPV,
		
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $KubeconfigPath
    )
	
    SetKubectl

    $pvcNames = [array](& $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace get pvc --no-headers -o custom-columns=":metadata.name")
    $pvcNames = $pvcNames | Where-Object { $_ -ne "asemigrationvol" }

    CreateDataTransferPVC -Namespace $Namespace -PVName $TargetPV -KubeconfigPath $KubeconfigPath

    foreach ($pvc in $pvcNames)
    {
        Write-Output "Moving data from PVC: $pvc"
        Copy-PVCDataInternal -Namespace $Namespace -PVCName $pvc -KubeconfigPath $KubeconfigPath
    }

    DeleteDataTransferPVC -Namespace $Namespace -KubeconfigPath $KubeconfigPath
}

function Restore-PVCData
{
    [CmdletBinding()]
    Param
    (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Namespace,

        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $PVCNames,

        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePV,
		
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $KubeconfigPath
    )

    SetKubectl

    CreateDataTransferPVC -Namespace $Namespace -PVName $SourcePV -KubeconfigPath $KubeconfigPath

    foreach ($pvc in $PVCNames)
    {
        Restore-PVCDataInternal -Namespace $Namespace -PVCName $pvc -KubeconfigPath $KubeconfigPath
    }

    DeleteDataTransferPVC -Namespace $Namespace -KubeconfigPath $KubeconfigPath
}

function Copy-PVCDataInternal
{
    [CmdletBinding()]
    Param
    (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Namespace,

        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $PVCName,
		
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $KubeconfigPath
    )
	
    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace delete pod "data-mover" --ignore-not-found=true

    $podYaml ='
apiVersion: v1
kind: Pod
metadata:
  name: data-mover
spec:
  containers:
  - args:
    - -c
    - apt-get update; apt -y install acl; rm -rf /mnt/dest/SOURCE_PVC_NAME; mkdir -p /mnt/dest/SOURCE_PVC_NAME/data; cp -r /mnt/src/. /mnt/dest/SOURCE_PVC_NAME/data/; cd /mnt/src/; getfacl -R . > /mnt/dest/SOURCE_PVC_NAME/permission.facl
    command:
    - /bin/sh
    image: ubuntu:24.04
    name: data-mover
    volumeMounts:
    - mountPath: /mnt/src
      name: sourcevolume
    - mountPath: /mnt/dest
      name: targetvolume
  restartPolicy: Never
  volumes:
  - name: sourcevolume
    persistentVolumeClaim:
      claimName: SOURCE_PVC_NAME
  - name: targetvolume
    persistentVolumeClaim:
      claimName: asemigrationvol
'

    $tmpFile = New-TemporaryFile
    $podYaml.Replace('SOURCE_PVC_NAME', $PVCName) | Out-File -FilePath $tmpFile
    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace apply -f $tmpFile

    WaitForDataMove -Namespace $Namespace -KubeconfigPath $KubeconfigPath

    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace delete pod "data-mover" --ignore-not-found=true
    Remove-Item $tmpFile
}

function Restore-PVCDataInternal
{
    [CmdletBinding()]
    Param
    (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Namespace,

        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $PVCName,
		
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $KubeconfigPath
    )
	
    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace delete pod "data-mover" --ignore-not-found=true

    $podYaml ='
apiVersion: v1
kind: Pod
metadata:
  name: data-mover
spec:
  containers:
  - args:
    - -c
    - apt-get update; apt -y install acl; rm -rf /mnt/dest/*; cp -r /mnt/src/DEST_PVC_NAME/data/. /mnt/dest/; cd /mnt/dest/; setfacl --restore=/mnt/src/DEST_PVC_NAME/permission.facl
    command:
    - /bin/sh
    image: ubuntu:24.04
    name: data-mover
    volumeMounts:
    - mountPath: /mnt/src
      name: migrationvolume
    - mountPath: /mnt/dest
      name: restorevolume
  restartPolicy: Never
  volumes:
  - name: restorevolume
    persistentVolumeClaim:
      claimName: DEST_PVC_NAME
  - name: migrationvolume
    persistentVolumeClaim:
      claimName: asemigrationvol
'

    $tmpFile = New-TemporaryFile
    $podYaml.Replace('DEST_PVC_NAME', $PVCName) | Out-File -FilePath $tmpFile
    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace apply -f $tmpFile

    WaitForDataMove -Namespace $Namespace -KubeconfigPath $KubeconfigPath

    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace delete pod "data-mover" --ignore-not-found=true
    Remove-Item $tmpFile
}

function CreateDataTransferPVC ([string] $Namespace, [string] $PVName, [string] $KubeconfigPath)
{
    $pvcYaml ='
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: asemigrationvol
spec:
  volumeName: MIGRATION_VOLUME_NAME
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
'
    $tmpFile = New-TemporaryFile
    $pvcYaml.Replace('MIGRATION_VOLUME_NAME', $PVName) | Out-File -FilePath $tmpFile

    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace apply -f $tmpFile
    Remove-Item $tmpFile
}

function DeleteDataTransferPVC ([string] $Namespace, [string] $KubeconfigPath)
{
    & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace delete pvc "asemigrationvol" --ignore-not-found=true
}

function  WaitForDataMove ([string] $Namespace, [string] $KubeconfigPath)
{    
    $startTime = Get-Date
    $podSuccess = $false

    while (((Get-Date) - $startTime).Minutes -lt 15)
    {
        $podState = & $global:Kubectl --kubeconfig $KubeconfigPath -n $Namespace get pod "data-mover" -o jsonpath="{.status.phase}"
        if ($podState -eq "Succeeded")
        {
            $podSuccess = $true
            break;
        }

        Start-Sleep -Seconds 10
    }

    if ($podSuccess)
    {
        return
    }

    throw "Data mover pod didn't succeed"
}

function SetKubectl()
{
    # Check if kubectl.exe exists on the system.
    $res = Get-Command kubectl.exe -ErrorAction SilentlyContinue
    if ($null -ne $res)
    {
        $global:Kubectl = $res.Source
    }
    else {
        $global:Kubectl = "$PSScriptRoot\kubectl.exe"
        if (-not (Test-Path -Path $global:Kubectl))
        {
            # Download kubectl.exe
            Write-Output "Downloading kubectl.exe"
            Invoke-WebRequest "https://dl.k8s.io/release/v1.27.0/bin/windows/amd64/kubectl.exe" -OutFile $global:Kubectl
        }
    }
}

Export-ModuleMember -Function Copy-PVCData, Restore-PVCData