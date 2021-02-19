<#
.SYNOPSIS
    Enable Azure Virtual Machine Insights Health capabilities (Health Data Collection).

.DESCRIPTION
    This script enabled Virtual Machine Insights Health define the thresholds for Health agent alert.
    IMPORTANT:
    This is currently in preview; your Log Analytics must be located in any of the following region
Central US
East US
East US 2
East US 2 EUAP
North Europe
Southeast Asia
UK South
West Europe region
West US 2

    Your virtual machine can be located in any for the following region
Australia Central
Australia East
Australia Southeast
Central India
Central US
East Asia
East US
East US 2
East US 2 EUAP
Germany West Central
Japan East
North Central US
North Europe
South Central US
Southeast Asia
UK South
West Central US
West Europe
West US
West US 2


.PARAMETER (optional) rgazresources
    Specify the Azure resource group where the virtual machines or virtual machine scale set are located; used only to limit the scope of execution

.PARAMETER (mandatory) fileslocatio
    Specify the location of the parameter file to be used for the deployment

.PARAMETER (mandatory) loganalyticworkspaceid and loganalyticworkspacerg
    Specify the Log Analytics workspace ID and resource group of the Log Analytics; this is required to validate the VM has been onboarded on VM Insights and if not to onboard them

.NOTES
    FileName:    azuremvminsights_health.ps1
    Author:      Benoit HAMET - cubesys
    Contact:     
    Created:     2021-02-12

    Version history:
    1.0.0 - (2020-02-12) - Script created

#>

#Script to enable VM Insights Health
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

#JSON VM Health template file
$templatefilepath = "$psscriptroot\template_vm_vminsights_health.json"
#JSON VM Health parameters file
$parametersfilepath = "$psscriptroot\$fileslocation\parameters_vminsights_health.json"

# supported regions for virtual machine
$supportedvmregions = @(
    "Australia East", "australiaeast",
    "Australia Central", "australiacentral",
    "Australia Southeast", "australiasoutheast",
    "Brazil South", "brazilsouth",
    "Brazil Southeast", "brazilsoutheast",
    "Canada Central", "canadacentral", 
    "Central India", "centralindia",
    "Central US", "centralus",
    "East Asia", "eastasia",
    "East US", "eastus",
    "East US 2", "eastus2",
    "East US 2 EUAP", "eastus2euap",
    "France Central", "francecentral",
    "Japan East", "japaneast",
    "Japan West", "japanwest",
    "North Central US", "northcentralus",
    "North Europe", "northeurope",
    "Norway East", "norwayeast",
    "South Africa North", "southafricanorth",
    "Southeast Asia", "southeastasia",
    "South Central US", "southcentralus",
    "Switzerland North", "switzerlandnorth",
    "Switzerland West", "switzerlandwest",
    "UAE Central", "uaecentral",
    "UAE North", "uaenorth",
    "UK South", "uksouth",
    "West Central US", "westcentralus",
    "West Europe", "westeurope",
    "West US", "westus",
    "West US 2", "westus2",
    "USGov Arizona", "usgovarizona",
    "USGov Virginia", "usgovvirginia"
)

# supported regions for Health
$supportedhealthregions = @(
    "Canada Central", "canadacentral",
    "East US", "eastus",
    "East US 2 EUAP", "eastus2euap",
    "Southeast Asia", "southeastasia",
    "UK South", "uksouth",
    "West Central US", "westcentralus", 
    "West Europe", "westeurope"
)

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
        Write-Output "The resource group you have defined in the parameter is not found"
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
    Write-Output "The Log Analytics workspace you have defined in the parameter is not found"
    Throw
}
#endregion Checks

#Gather Log Analytics workspace details
$loganalyticsworkspace = Get-AzOperationalInsightsWorkspace -Name $loganalyticworkspacename -ResourceGroupName $loganalyticworkspacerg
$workspaceid = $loganalyticsworkspace.CustomerID.Guid
$workspaceresid = $loganalyticsworkspace.ResourceId
$workspaceregion = $loganalyticsworkspace.Location
$workspacesku = $loganalyticsworkspace.Sku

$subscriptionid = (Get-AzContext).Subscription

#quit if workspace not located in supported region
If (!($supportedhealthregions -contains $workspaceregion))
{
    Write-Output "The Log Analytics workspace is not located in a supported region"
    Throw
}
Else
{

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

#continue only if the VM is located in a supported region
            If ($supportedvmregions -contains $vmlocation)
            {
                Write-Output "Enabling VM Insights Health on virtual machine $vmname"
                $mmaextinstalled = $false
                $daextinstalled = $false
                $guestextinstalled = $false
                $monitorextinstalled = $false
                $insightsextensionsinstalled = $false
                $healthextensionsinstalled = $false

#Check if a Data Collection Rule exists
                $dcr = Get-AzDataCollectionRule
                If (!($dcr))
                {
#Set the DCR to use
                    $dcrname = $dcr.Name
                    [string]$healthdcrid = "/subscriptions/" + $subscriptionid + "/resourceGroups/" + $loganalyticworkspacerg + "/providers/Microsoft.Insights/dataCollectionRules/" + $dcrname
                }
#Deploy the DCR
                Else
                {
                    #JSON Health Data Collection Rule (DCR) template file
                    $dcrtemplatefilepath = "$psscriptroot\template_vm_vminsights_health_dcr.json"
                    #JSON Health Data Collection Rule (DCR) parameters file
                    $dcrparametersfilepath = "$psscriptroot\$fileslocation\parameters_vminsights_health_dcr.json"
#Parameters
                    {
                        $paramfile = Get-Content $dcrparametersfilepath -Raw | ConvertFrom-Json
                        $paramfile.parameters.destinationWorkspaceResourceId.value = $workspaceresid
                        $paramfile.parameters.dataCollectionRuleLocation.value = $workspaceregion

                #Update parameters file JSON
                        $updatedjson = $paramfile | ConvertTo-Json
                        $updatedjson > $dcrparametersfilepath

                #Deploy VM Insights
                        $deploymentname = "VMInsightsHealthDCR-" + $loganalyticworkspacename
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

                        Write-Output "Deploy VM Insight Health Data Collection Rule on Log Analytics workspace $loganalyticworkspacename"
                        New-AzResourceGroupDeployment -Name $deploymentname -ResourceGroupName $dcrtemplatefilepath -TemplateFile $templatefilepath -TemplateParameterFile $dcrparametersfilepath -AsJob
                    }
                }


#Set extensions values
                If ($vmos -eq "Windows")
                {
                    $guesthealthagentname = "GuestHealthWindowsAgent"
                    $guesthealthagentexttype = "GuestHealthWindowsAgent"
                    $guesthealthagentextversion = "1.0"
                    $monitoragentname = "AzureMonitorWindowsAgent"
                    $monitoragentexttype = "AzureMonitorWindowsAgent"
                    $monitoragentextversion = "1.10"
                    $mmaagentname = "MMAExtension"
                    $mmaagentexttype = "MicrosoftMonitoringAgent"
                    $mmaagentextversion = "1.0"
                    $daagentname = "DependencyAgentWindows"
                    $daagentexttype = "DependencyAgentWindows"
                    $ddagentextversion = "9.10"
                }
                Else
                {
                    $guesthealthagentname = "GuestHealthLinuxAgent"
                    $guesthealthagentexttype = "GuestHealthLinuxAgent"
                    $guesthealthagentextversion = "1.0"
                    $monitoragentname = "AzureMonitorLinuxAgent"
                    $monitoragentexttype = "AzureMonitorLinuxAgent"
                    $monitoragentextversion = "1.5"
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
                        Write-Output "Starting virtual machine $vmname"
                        Start-AzVM -Name $vmname -ResourceGroupName $vmrg -Confirm:$false
                    }
                Catch
                    {
                        $_.Exception.Message
                    }
                }
#Get installed extensions
                $extensions = Get-AzVMExtension -VMName $vmname -ResourceGroupName $vmrg


#Check if Guest Health and Azure Monitoring extensions are installed
                ForEach ($vmextension in $extensions)
                {
                    $vmextensionname = $vmextension.Name

#Check if MMA extension is installed
                    If ($vmextensionname -eq $mmaagentexttype)
                    {
                        $mmaextinstalled = $true
                    }

#Check if DA extension is installed
                    If ($vmextensionname -eq $daagentexttype)
                    {
                        $daextinstalled = $true
                    }

#If both extension are installed and configured
                    If (($mmaextinstalled -eq $true) -and ($daextinstalled -eq $true))
                    {
                        $insightsextensionsinstalled = $true
                    }

#Check if Guest Health extension is installed
                    If ($vmextensionname -eq $guesthealthagentexttype)
                    {
                        $guestextinstalled = $true
                    }

#Check if Azure Monitoring extension is installed
                    If ($vmextensionname -eq $monitoragentexttype)
                    {
                        $monitorextinstalled = $true
                    }

#If both extension are installed and configured
                    If (($guestextinstalled -eq $true) -and ($monitorextinstalled -eq $true))
                    {
                        $healthextensionsinstalled = $true
                    }
                }

#Only if extensions are not installed, call the VM Insight onboarding script
                If ($insightsextensionsinstalled -eq $false)
	            {
		            Write-Output "You need to onboard onto VM Insights first"
	            }

#Enable VM Insights Health if not already enabled
                
                If ($healthextensionsinstalled -eq $false)
                {
#Parameters
                    {
                        $paramfile = Get-Content $parametersfilepath -Raw | ConvertFrom-Json
                        $paramfile.parameters.virtualMachineName.value = $vmname
                        $paramfile.parameters.virtualMachineLocation.value = $vmlocation
                        $paramfile.parameters.virtualMachineOsType.value = $vmos
                        $paramfile.parameters.dataCollectionRuleAssociationName.value = "VM-Health-Dcr-Association"
                        $paramfile.parameters.healthDataCollectionRuleResourceId.value = $healthdcrid

#Update parameters file JSON
                        $updatedjson = $paramfile | ConvertTo-Json
                        $updatedjson > $parametersfilepath

#Deploy VM Insights
                        $deploymentname = "VMInsightsHealthOnboarding-" + $vmname
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

                        Write-Output "Enable VM Insights Health on virtual machine $vmname"
                        New-AzResourceGroupDeployment -Name $deploymentname -ResourceGroupName $vmrg -TemplateFile $templatefilepath -TemplateParameterFile $parametersfilepath -AsJob
                    }
                }
            }
        }
    }
}