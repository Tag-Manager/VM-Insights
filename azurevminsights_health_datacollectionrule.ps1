<#
.SYNOPSIS
    Deploy Azure Virtual Machine Insights Health Data Collection Rule (DCR).

.DESCRIPTION
    This script deploy Data Collection Rule for VM Insights Health agent alert.
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

.PARAMETER (mandatory) fileslocation
    Specify the location of the parameter file to be used for the deployment

.PARAMETER (mandatory) loganalyticworkspaceid and loganalyticworkspacerg
    Specify the Log Analytics workspace ID and resource group of the Log Analytics; this is required to validate the VM has been onboarded on VM Insights and if not to onboard them

.NOTES
    FileName:    azurevminsights_health_datacollectionrule.ps1
    Author:      Benoit HAMET - cubesys
    Contact:     
    Created:     2021-02-12

    Version history:
    1.0.0 - (2020-02-12) - Script created

#>

#Script to set threshold values for monitoring components
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

#JSON Health Data Collection Rule (DCR) template file
$templatefilepath = "$psscriptroot\template_vm_vminsights_health_dcr.json"
#JSON Health Data Collection Rule (DCR) parameters file
$parametersfilepath = "$psscriptroot\$fileslocation\parameters_vminsights_health_dcr.json"

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
$workspaceresid = $loganalyticsworkspace.ResourceId
$workspaceregion = $loganalyticsworkspace.Location

#quit if workspace not located in supported region
If (!($supportedhealthregions -contains $workspaceregion))
{
    Write-Output "The Log Analytics workspace is not located in a supported region" -ForegroundColor Red -BackgroundColor Black
    Throw
}
Else
{
#Register the Agent Health resource provider
    $registrationstate = (Get-AzResourceProvider -ProviderNamespace Microsoft.AlertsManagement).RegistrationState
    If ($registrationstate -ne "Registered")
    {
        Write-Output "Register the Resource Provider Microsoft.AlertsManagement for Health feature"
        Register-AzResourceProvider -ProviderNamespace Microsoft.AlertsManagement
    }

#Parameters
    {
        $paramfile = Get-Content $parametersfilepath -Raw | ConvertFrom-Json
        $paramfile.parameters.destinationWorkspaceResourceId.value = $workspaceresid
        $paramfile.parameters.dataCollectionRuleLocation.value = $workspaceregion

#Update parameters file JSON
        $updatedjson = $paramfile | ConvertTo-Json
        $updatedjson > $parametersfilepath

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
        New-AzResourceGroupDeployment -Name $deploymentname -ResourceGroupName $loganalyticworkspacerg -TemplateFile $templatefilepath -TemplateParameterFile $parametersfilepath #-AsJob
    }
}
