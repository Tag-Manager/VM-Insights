<#
.SYNOPSIS
    Enable Azure Virtual Machine Insights monitoring capabilities.

.DESCRIPTION
    This script will automatically onboard virtual machines in Virtual Machines Insights.

.PARAMETER rgazresources
    Specify the Azure resource group where the virtual machines or virtual machine scale set are located; used only to limit the scope of execution

.PARAMETER (mandatory) fileslocation
    Specify the location of the parameter file to be used for the deployment

.PARAMETER loganalyticworkspaceid
    Specify the Log Analytics workspace ID

.NOTES
    FileName:    azuremvminsights.ps1
    Author:      Benoit HAMET - cubesys
    Contact:     
    Created:     2021-02-08

    Version history:
    1.0.0 - (2020-02-08) - Script created

#>

#Script to enable VM Insights
#region Parameters
Param(
#Resource Group where resources are located - if need to filter to a specifc RG instead of the complete subscription
    [Parameter(Mandatory=$false)]
    $rgazresources,

#Location of the parameter.json file
    [Parameter(Mandatory=$true)]
    $fileslocation,

#Log Analytics workspace name
    [Parameter(Mandatory=$true)]
    $loganalyticworkspacename,

#Log Analytics workspace resource group
    [Parameter(Mandatory=$true)]
    $loganalyticworkspacerg
)
#endregion Parameters


#Define default behavior when error occurs
$erroractionpreference = [System.Management.Automation.ActionPreference]::Stop

#JSON parameters file
$parametersfilepath = "$psscriptroot\$fileslocation\parameters_vminsights.json"

#region Checks
#Checking if the resource group defined in parameter is found or if the resouce type defined is enabled for monitoring
If ($rgazresources)
{
    Try
    {
        $checkrg = Get-AzResourceGroup -Name $rgazresources
    }
    Catch
    {
        Write-Host "The resource group you have defined in the parameter is not found" -ForegroundColor Red -BackgroundColor Black
        Throw
    }
}
#Check if the Log Analytics workspace exist
Try
{
    $checkworkspace = Get-AzOperationalInsightsWorkspace -Name $loganalyticworkspacename -ResourceGroupName $loganalyticworkspacerg
}
Catch
{
    Write-Host "The Log Analytics workspace you have defined in the parameter is not found" -ForegroundColor Red -BackgroundColor Black
    Throw
}
#endregion Checks

#Gather Log Analytics workspace details
$loganalyticsworkspace = Get-AzOperationalInsightsWorkspace -Name $loganalyticworkspacename -ResourceGroupName $loganalyticworkspacerg
$workspaceid = $loganalyticsworkspace.CustomerID.Guid
$workspaceresid = $loganalyticsworkspace.ResourceId
$workspaceregion = $loganalyticsworkspace.Location
$workspacesku = $loganalyticsworkspace.Sku

#region virtual machines
#if filtered to a specific resource group
If ($rgazresources)
{
    $vms = Get-AzVM -ResourceGroupName $rgazresources
    $vmsss = Get-AzVmss -ResourceGroupName $rgazresources
}
Else
{
	$vms = Get-AzVM
    $vmsss = Get-AzVmss
}

If ($vms.Count -gt 0)
{
    ForEach($vm in $vms)
    {
        [string]$vmname = $vm.Name
        [string]$vmrg = $vm.ResourceGroupName
        [string]$vmlocation = $vm.Location
        [string]$vmid = $vm.Id
        [string]$vmos = $vm.StorageProfile.OsDisk.OsType
        [string]$vmtype = ($vm.Type).Replace("Microsoft.Compute/","")

        $templatefilepath = "$psscriptroot\template_vm_vminsights.json"

        $mmaextinstalled = $false
        $daextinstalled = $false
        $exensionsinstalled = $false

#Set extensions values
        If ($vmos -eq "Windows")
        {
            $mmaagentname = "MMAExtension"
            $mmaagentexttype = "MicrosoftMonitoringAgent"
            $mmaagentextversion = "1.0"
            $daagentname = "DependencyAgentWindows"
            $daagentexttype = "DependencyAgentWindows"
            $ddagentextversion = "9.10"
        }
        Else
        {
            $mmaagentname = "OMSExtension"
            $mmaagentexttype = "OmsAgentForLinux"
            $mmaagentextversion = "1.7"
            $daagentname = "DependencyAgentLinux"
            $daagentexttype = "DependencyAgentLinux"
            $ddagentextversion = "9.10"
        }

        $vmstatus = (Get-AzVM -Status -Name $vmname).PowerState
#Check if VMs are started
        If ($vmstatus -ne "VM running")
        {
            Try
            {
                Write-Host "Starting virtual machine" $vmname -ForegroundColor Green -BackgroundColor Black
                Start-AzVM -Name $vmname -ResourceGroupName $vmrg -Confirm:$false
            }
        Catch
            {
                $_.Exception.Message
            }
        }
#Get installed extensions
	    $extensions = Get-AzVMExtension -VMName $vmname -ResourceGroupName $vmrg


#Check if MMA and DA extensions are installed
        ForEach ($vmextension in $extensions)
        {
            $vmextensionname = $vmextension.Name
#Check if MMA extension is installed
            If ($vmextensionname -eq $mmaagentexttype)
            {
                $mmaextinstalled = $true
#Check if MMA extension is already connected to the Log Analytics workspace
                If (!$vmextension.PublicSettings.ToString().Contains($workspaceid))
                {
#Uninstall if connected to another workspace
                    Try
                    {
                        $mmaextinstalled = $false
                        Write-Host "Uninstalling extension " $mmaagentname " on VM " $vmname
                        Remove-AzVMExtension -VMName $vmname -ResourceGroupName $vmrg -Name $mmaagentexttype -Force
#Wait for extension to be uninstalled
                        Start-Sleep -Seconds 120
                    }
                    Catch
                    {
                        $_.Exception.Message
                    }
                }
            }
#Check if DA extension is installed
            If ($vmextensionname -eq $daagentexttype)
            {
                $daextinstalled = $true
            }
#If both extension are installed and configured
            If (($mmaextinstalled -eq $true) -and ($daextinstalled -eq $true))
            {
                $exensionsinstalled = $true
            }
        }

#Only if extensions are not installed
        If ($exensionsinstalled -ne $true)
        {
#Parameters
            $paramfile = Get-Content $parametersfilepath -Raw | ConvertFrom-Json
            $paramfile.parameters.vmName.value = $vmname
            $paramfile.parameters.vmLocation.value = $vmlocation
            $paramfile.parameters.vmResourceId.value = $vmid
            $paramfile.parameters.vmType.value = $vmtype
            $paramfile.parameters.osType.value = $vmos
            $paramfile.parameters.mmaAgentName.value = $mmaagentexttype
            $paramfile.parameters.mmaExtensionType.value = $mmaagentexttype
            $paramfile.parameters.mmaExtensionVersion.value = $mmaagentextversion
            $paramfile.parameters.daExtensionName.value = $daagentexttype
            $paramfile.parameters.daExtensionType.value = $daagentexttype
            $paramfile.parameters.daExtensionVersion.value = $ddagentextversion
            $paramfile.parameters.workspaceId.value = $workspaceid
            $paramfile.parameters.workspaceResourceId.value = $workspaceresid
            $paramfile.parameters.workspaceLocation.value = $workspaceregion
            $paramfile.parameters.omsWorkspaceSku.value = $workspacesku

#Update parameters file JSON
            $updatedjson = $paramfile | ConvertTo-Json
            $updatedjson > $parametersfilepath

#Deploy VM Insights
            $deploymentname = "VMInsightsOnboarding-" + $vmname
#Esnure deployment name is supported
#Remove space
            If ($deploymentname -like '* *')
            {
                $deploymentname = $deploymentname -replace (' ','-')
            }
#Remove / character
            If ($deploymentname -like '*/*')
            {
                $deploymentname = $deploymentname -replace ('/','-')
            }
#Ensure deployment name is shorter than 64 characters
            If ($deploymentname.Length -ge 64)
            {
                $deploymentname = $deploymentname.Substring(0,64) 
            }

            Write-Host "Deploy VM Insights on virtual machine" $vmname -ForegroundColor Green -BackgroundColor Black
            New-AzResourceGroupDeployment -Name $deploymentname -ResourceGroupName $vmrg -TemplateFile $templatefilepath -TemplateParameterFile $parametersfilepath -AsJob
        }
    }
}
