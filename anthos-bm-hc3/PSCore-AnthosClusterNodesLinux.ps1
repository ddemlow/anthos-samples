#this script uses cloud-init to create a # of ubuntu VM from cloud-image
#cloud-init data comes from file (originally provided by google / terraform process)
#Bugs ...doesn't check if name already exists before import - but fails and continues
#Bugs ... doesn't validate if vmtargetname is valid for rancher cluster name or if it already exists (if it does nodes will just join)
#todos - would be nice to specify size of test disk here and create in template.
#done - changing ram / cores on template before cloning
param(
   [string] $clusterip = "10.100.20.25" , #HC3 cluster info
     [string]$user = "admin",
     [string] $pass = "admin",
    [bool] $useOIDC = $false ,
   [string] $autoclone = "Y",  #execute bulk clone script or not
   [string] $VMtargetName = "abm" , #must be all lower case - simple strict must consist of lower case alphanumeric characters or -
   [string] $VMmasterName = "ubuntu18_04-cloud-init-dave" , #master cloud-init image to use
    [int] $sleep = 10 , #seconds to sleep in between vm clone cycles
    #[string]$pathURI="https://github.lab.local/storage/raw_lfs/ddemlow/k8sdeploy/master/", #pathURI will have $VMmasterName apppended to it
    [string]$pathURI="smb://remotedc;administrator:Scale2010@10.4.0.9/azure-sync/", #not used   
    [long] $VMmem = 8589934592 , #vram in bytes to provision to clones
    [int] $VMnumVCPU = 6 , #vcores to provision to clones
    [int] $VMdiskGB = 300 , #size to expand disk to in GB 
    [int] $loopstart = 40 , #starting VM index #
    [int] $loops=5 ,  #here this is # of VM's to create
   [string] $CLUSTER_NAME = $VMtargetName  #anthos cluster name if different 
  )

# moving into HC3 rest api portion

#create object for HC3 login oidc capable
$login = @{
        username = $user;
        password = $pass;
        useOIDC =  $useOIDC
    } | ConvertTo-Json
#get HC3 session ID - is stored as powershell websession to allow re-use     
$sessionid = Invoke-RestMethod -SkipCertificateCheck  -Method POST -Uri https://$clusterip/rest/v1/login -Body $login -ContentType 'application/json' -SessionVariable mywebSession

#get list of VMs - virdomain information 
$VM = Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/VirDomain -WebSession $mywebsession

#region IMPORT VM - for cloud-init template
#create object for import options
$importoptions = [ordered]@{
    source = [ordered]@{pathURI=$pathURI ; definitionFileName=$definitionFileName } ;
        
    template = [ordered]@{name=$name;}
        }
        

#set import options
$importoptions.source.pathURI=$pathURI +$VMmasterName
$importoptions.source.definitionFileName=$VMmasterName  +".xml"

#this is the name of the VM that will be created in HC3  
$importoptions.template.name=$VMmasterName

#convert to json
 #$task
$importoptionsJSON = $importoptions | ConvertTo-Json

#hc3 restapi - post to /VirDomain/import with json body
$NewVMTask = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/import -Body $importoptionsJSON  -ContentType 'application/json'  -WebSession $mywebsession

#capture task tag
$tasktag = $NewVMTask.taskTag
Write-Host Task tag for import test $tasktag

#wait for import to complete
Do {
$task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
$taskProgress= $task.progressPercent
 $task

if($taskProgress -lt 100 -and $task.state -ne "COMPLETE" )
{ 
Sleep 3
$task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
$taskProgress= $task.progressPercent
 #$task
 }
}
Until ( $taskProgress = 100 -and $task.state -eq "COMPLETE" )

Write-Host Import complete
$task
#endregion

#update vm list
$VM = Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/VirDomain -WebSession $mywebsession

Write-Host Looking for $VMmasterName
$VMMaster = $VM | Select-Object | where-object -Property name -EQ $VMmasterName
$VMUUID = $VMMaster.UUID
Write-Host $VMUUID

#create first VM - set variable to loopstart value ... allows first VM to be different than rest ... may be able to remove?
$i=$loopstart

#yaml for meta-data cloud-init payload - here just sets unique host name
$metaData = @"
dsmode: local
local-hostname: 
"@ + $VMtargetName+$i+
@" 
"@

#base64 encode meta-data
$metaData64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))

#get user-data from /resources/cloud-config.yaml
$content = Get-Content -Path ./anthos-bm-hc3/resources/cloud-config.yaml -Raw 

#base64 encode above content
$userdata64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))

#combine cloudInit data json
$cloudInitData = @{
        userData = $userData64
        metaData = $metaData64
} 

#create virdomain clone body
$json = @{
    snapUUID = ""
    template = @{
        name =  $VMtargetName+$i
        description = "SERIAL"  
        cloudInitData = $cloudInitData
        mem = $VMmem
        numVCPU = $VMnumVCPU           
    } 
} | ConvertTo-Json


#submit the clone operation
    $NewVMTask = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/$VMUUID/clone -WebSession $mywebsession -Body $json -ContentType 'application/json'
    $tasktag = $NewVMTask.taskTag
    #Wait for clone to complete to start it
    Do {
        $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
        $taskProgress= $task.progressPercent
        $task
        if($taskProgress -lt 100 -and $task.state -ne "COMPLETE" )
            { 
            Sleep 10
            $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
            $taskProgress= $task.progressPercent
            }
        }
    Until ( $taskProgress = 100 -and $task.state -eq "COMPLETE" )
    $CreatedUUID = $NewVMTask.createdUUID

#TODOThis is where I should expand the virtual disk to variable size above ... and change the mac address?
#get VM info
$CreatedVM=Invoke-RestMethod -SkipCertificateCheck -Method Get -Uri https://$clusterip/rest/v1/VirDomain/$CreatedUUID -WebSession $mywebsession 

#getblockdev - use simple approach assuming first disk [0]
$CreatedBlockDev=$CreatedVM.blockDevs[0].uuid

$jsonDISK = @'
{
    "capacity": 
'@ + $VMdiskGB*1000*1000*1000 +
@' 

}
'@

$PatchVMDisk=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomainBlockDevice/$CreatedBlockDev -WebSession $mywebsession -Body $jsonDISK -ContentType 'application/json'


#getnetdevs - can I just patch? $CreatedVM.netDevs.macAddress
$CreatedNetDev = $CreatedVM.netDevs.uuid
#json payload for patch 
#wasnt able to use convert to json because it would send an array and api would reject - so built this json manually
$jsonNET = @'
{
    "macAddress": "7C:4C:DD:00:00:
'@ + $i +
@'
" ,
    "vlan": 164
}
'@

$PatchVMNet=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomainNetDevice/$CreatedNetDev -WebSession $mywebsession -Body $jsonNET -ContentType 'application/json'


# START VM
    Write-Host "About to start"
    $jsonstart = ConvertTo-Json @(@{
        actionType = 'START'
        virDomainUUID = $CreatedUUID
        })

    $task = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/action -WebSession $mywebsession -Body $jsonSTART -ContentType 'application/json'
    $taskProgress= $task.progressPercent
    $task #TODO - remove this?
    Write-Host "Starting"
    $tasktag = $NewVMTask.taskTag
    #Wait for vm to start 
    Do {
        $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
        $taskProgress= $task.progressPercent
         $task
            if($taskProgress -lt 100 -and $task.state -ne "COMPLETE" )
                { 
                Sleep 3
                $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
                $taskProgress= $task.progressPercent
                }
        }
    Until ( $taskProgress = 100 -and $task.state -eq "COMPLETE" )

#Wait for IP from guest agent to report in virdomain.netDevs.ip4Addresses
#Do {
#$task = Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/VirDomain/$CreatedUUID -WebSession $mywebsession -ContentType 'application/json'
#Write-Host checkingip $task.netDevs.ipv4Addresses

#Loop to add additional nodes to initial node - note this is identical right now ... could simplify this code
For ($i=$i+1; $i -lt ($loops+$loopstart); $i++) 
{
Write-Host In Loop $i
$VMUUID

# create meta-data structure - set hostname
$metaData = @"
dsmode: local
local-hostname: 
"@ + $VMtargetName+$i+
@" 
"@

#base64 encode meta-data
$metaData64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))

<#re-using from above since reading from file ...
#base64 encode user-data
#$userData64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))
#>

#create full cloud-init payload
$cloudInitData = @{
        userData = $userData64
        metaData = $metaData64
} 

#create virdomain clone body
$json = @{
    snapUUID = ""
    template = @{
        name =  $VMtargetName+$i
        description = "SERIAL"  
        cloudInitData = $cloudInitData
        mem = $VMmem
        numVCPU = $VMnumVCPU    
    } 
} | ConvertTo-Json

#clone this VM
$NewVMTask = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/$VMUUID/clone -WebSession $mywebsession -Body $json -ContentType 'application/json'
$tasktag = $NewVMTask.taskTag

#Wait for clone to complete to start it
    Do {
        $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
        $taskProgress= $task.progressPercent
        $task
        if($taskProgress -lt 100 -and $task.state -ne "COMPLETE" )
            {    
            Sleep 3
            $task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
            $taskProgress= $task.progressPercent
            }
        }
    Until ( $taskProgress = 100 -and $task.state -eq "COMPLETE" )

 #update VM infohere - createdUUID from $NewVMTask
 $CreatedUUID = $NewVMTask.createdUUID
 $CreatedVM=Invoke-RestMethod -SkipCertificateCheck -Method Get -Uri https://$clusterip/rest/v1/VirDomain/$CreatedUUID -WebSession $mywebsession 

#getblockdev - use simple approach assuming first disk [0]
$CreatedBlockDev=$CreatedVM.blockDevs[0].uuid

$jsonDISK = @'
{
    "capacity": 
'@ + $VMdiskGB*1000*1000*1000 +
@' 

}
'@

$PatchVMDisk=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomainBlockDevice/$CreatedBlockDev -WebSession $mywebsession -Body $jsonDISK -ContentType 'application/json'




#getnetdevs - can I just patch? $CreatedVM.netDevs.macAddress
$CreatedNetDev = $CreatedVM.netDevs.uuid

#create json payload for patch 
#wasnt able to use convert to json because it would send an array and api would reject - so built this json manually
$jsonNET = @'
{
    "macAddress": "7C:4C:DD:00:00:
'@ + $i +
@'
" ,
    "vlan": 164
}
'@

$PatchVMNet=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomainNetDevice/$CreatedNetDev -WebSession $mywebsession -Body $jsonNET -ContentType 'application/json'



Write-Host "About to start"
# START VM

$jsonstart = ConvertTo-Json @(@{
    actionType = 'START'
    virDomainUUID = $CreatedUUID
})

$task = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/action -WebSession $mywebsession -Body $jsonSTART -ContentType 'application/json'
$taskProgress= $task.progressPercent
 $task

Write-Host "Starting"

$tasktag = $NewVMTask.taskTag

#Wait for vm to start 
Do {
$task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
$taskProgress= $task.progressPercent
 $task

if($taskProgress -lt 100 -and $task.state -ne "COMPLETE" )
{ 
Sleep 3
$task =Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$clusterip/rest/v1/TaskTag/$tasktag -WebSession $mywebsession
$taskProgress= $task.progressPercent
 #$task
 }
}
Until ( $taskProgress = 100 -and $task.state -eq "COMPLETE" )
 #$task

#Wait for IP- don't need to do this for additional masters
$task
}

Write-Host
Write-Host about to log out
Invoke-RestMethod -SkipCertificateCheck  -Method POST -Uri https://$clusterip/rest/v1/logout -WebSession $mywebsession

Write-Host
Write-Host Run on (Get-Date)   
