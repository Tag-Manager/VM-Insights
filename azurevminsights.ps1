<#
.SYNOPSIS
    Enable Azure Virtual Machine Insights monitoring capabilities.

.DESCRIPTION
    This script will automatically onboard virtual machines in Virtual Machines Insights.

.PARAMETER rgazresources
    Specify the Azure resource group where the virtual machines or virtual machine scale set are located; used only to limit the scope of execution

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

#Script to set threshold values for monitoring components
#region Parameters
Param(
#Resource Group where resources are located - if need to filter to a specifc RG instead of the complete subscription
    [Parameter(Mandatory=$false)]
    $rgazresources,

#Location ofand parameter.json file
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
$vms = Get-AzVM
$vmsss = Get-AzVmss


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

# SIG # Begin signature block
# MIIThQYJKoZIhvcNAQcCoIITdjCCE3ICAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUooBhD3vSLztI6rjGogk5OrWZ
# RJCgghC8MIIFOjCCBCKgAwIBAgIRAMAkGCkl6rgosyKOhFWhX14wDQYJKoZIhvcN
# AQELBQAwfDELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3Rl
# cjEQMA4GA1UEBxMHU2FsZm9yZDEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSQw
# IgYDVQQDExtTZWN0aWdvIFJTQSBDb2RlIFNpZ25pbmcgQ0EwHhcNMjAxMTIwMDAw
# MDAwWhcNMjMxMTIwMjM1OTU5WjB+MQswCQYDVQQGEwJBVTENMAsGA1UEEQwEMjAw
# MDEPMA0GA1UEBwwGU3lkbmV5MRswGQYDVQQJDBJMZXZlbCAyLzQ0IFBpdHQgU3Qx
# GDAWBgNVBAoMD0NVQkVTWVMgUFRZIExURDEYMBYGA1UEAwwPQ1VCRVNZUyBQVFkg
# TFREMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAod6TgHNzGaGyOwCe
# YYVxIk3gIP2A4DH8iyVNX6f8AGnXZ5b5SgDnYLb43/eYDgSIiDqxRPgYdX7n5q6v
# xB/4rWKbNTWSbsIJnkRx7AjS3d1erqCRAOQvWOqGL3kEdrL/fdkvlIDZ6Pcq3Gin
# aCe6upC3otSaSomQAqNltzumvCN6lp1NdmvQOjxncttUncFmaABOqFgaO78i95IF
# /hsEz2TyAvM61qe+NEm9SnmF0jTkwGYQ2+cNbFV734rvOsoxOJ0hXDnNIgjrbjzW
# rHAn5mk4G0Z8yLM5kL69WNn8730EGBe+F+HM589PJgDixWRXSJ97Jf/ChQazCpiw
# 86XeQQIDAQABo4IBszCCAa8wHwYDVR0jBBgwFoAUDuE6qFM6MdWKvsG7rWcaA4Wt
# NA4wHQYDVR0OBBYEFObv4MQdB9HUJAd58GxnKMbiwgdMMA4GA1UdDwEB/wQEAwIH
# gDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMBEGCWCGSAGG+EIB
# AQQEAwIEEDBKBgNVHSAEQzBBMDUGDCsGAQQBsjEBAgEDAjAlMCMGCCsGAQUFBwIB
# FhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBBAEwQwYDVR0fBDwwOjA4
# oDagNIYyaHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUlNBQ29kZVNpZ25p
# bmdDQS5jcmwwcwYIKwYBBQUHAQEEZzBlMD4GCCsGAQUFBzAChjJodHRwOi8vY3J0
# LnNlY3RpZ28uY29tL1NlY3RpZ29SU0FDb2RlU2lnbmluZ0NBLmNydDAjBggrBgEF
# BQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wIQYDVR0RBBowGIEWc3VwcG9y
# dEBjdWJlc3lzLmNvbS5hdTANBgkqhkiG9w0BAQsFAAOCAQEAJgGu99/CNblxUOV3
# fk7nZ+3vJgoSJ59vJlb8ZhdBYZmXGicUuii6W5yo/VlClXgBkydIHlvf6HjE4SKa
# 7NfcK1wU9PkH09hUOfkhTAYYmsWAlBfS4ClNsITRy7y4fgXj5cJDnkBzAc1UkM3G
# Gi2iLfVGxeAAzm4BMSIcwFNoKPA3QOiWZVt70dP0eQj7LLl4lB6LtHwGfbcDNq4G
# V1lY+04lhPAV4slN7J8rDi2+HeK83P4ImaaSInujF49vg3rPI40S+Ju9DQpPDtsQ
# bXa42CF6dmFlJy1pP7JhzrwS1SMWBNyJ4xJLPVpaV2LHwlIcJQCytfYyFO7tazDQ
# GmTdCzCCBYEwggRpoAMCAQICEDlyRDr5IrdR19NsEN0xNZUwDQYJKoZIhvcNAQEM
# BQAwezELMAkGA1UEBhMCR0IxGzAZBgNVBAgMEkdyZWF0ZXIgTWFuY2hlc3RlcjEQ
# MA4GA1UEBwwHU2FsZm9yZDEaMBgGA1UECgwRQ29tb2RvIENBIExpbWl0ZWQxITAf
# BgNVBAMMGEFBQSBDZXJ0aWZpY2F0ZSBTZXJ2aWNlczAeFw0xOTAzMTIwMDAwMDBa
# Fw0yODEyMzEyMzU5NTlaMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKTmV3IEpl
# cnNleTEUMBIGA1UEBxMLSmVyc2V5IENpdHkxHjAcBgNVBAoTFVRoZSBVU0VSVFJV
# U1QgTmV0d29yazEuMCwGA1UEAxMlVVNFUlRydXN0IFJTQSBDZXJ0aWZpY2F0aW9u
# IEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAIASZRc2
# DsPbCLPQrFcNdu3NJ9NMrVCDYeKqIE0JLWQJ3M6Jn8w9qez2z8Hc8dOx1ns3KBEr
# R9o5xrw6GbRfpr19naNjQrZ28qk7K5H44m/Q7BYgkAk+4uh0yRi0kdRiZNt/owbx
# iBhqkCI8vP4T8IcUe/bkH47U5FHGEWdGCFHLhhRUP7wz/n5snP8WnRi9UY41pqdm
# yHJn2yFmsdSbeAPAUDrozPDcvJ5M/q8FljUfV1q3/875PbcstvZU3cjnEjpNrkyK
# t1yatLcgPcp/IjSufjtoZgFE5wFORlObM2D3lL5TN5BzQ/Myw1Pv26r+dE5px2uM
# YJPexMcM3+EyrsyTO1F4lWeL7j1W/gzQaQ8bD/MlJmszbfduR/pzQ+V+DqVmsSl8
# MoRjVYnEDcGTVDAZE6zTfTen6106bDVc20HXEtqpSQvf2ICKCZNijrVmzyWIzYS4
# sT+kOQ/ZAp7rEkyVfPNrBaleFoPMuGfi6BOdzFuC00yz7Vv/3uVzrCM7LQC/NVV0
# CUnYSVgaf5I25lGSDvMmfRxNF7zJ7EMm0L9BX0CpRET0medXh55QH1dUqD79dGMv
# sVBlCeZYQi5DGky08CVHWfoEHpPUJkZKUIGy3r54t/xnFeHJV4QeD2PW6WK61l9V
# LupcxigIBCU5uA4rqfJMlxwHPw1S9e3vL4IPAgMBAAGjgfIwge8wHwYDVR0jBBgw
# FoAUoBEKIz6W8Qfs4q8p74Klf9AwpLQwHQYDVR0OBBYEFFN5v1qqK0rPVIDh2JvA
# nfKyA2bLMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MBEGA1UdIAQK
# MAgwBgYEVR0gADBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsLmNvbW9kb2Nh
# LmNvbS9BQUFDZXJ0aWZpY2F0ZVNlcnZpY2VzLmNybDA0BggrBgEFBQcBAQQoMCYw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmNvbW9kb2NhLmNvbTANBgkqhkiG9w0B
# AQwFAAOCAQEAGIdR3HQhPZyK4Ce3M9AuzOzw5steEd4ib5t1jp5y/uTW/qofnJYt
# 7wNKfq70jW9yPEM7wD/ruN9cqqnGrvL82O6je0P2hjZ8FODN9Pc//t64tIrwkZb+
# /UNkfv3M0gGhfX34GRnJQisTv1iLuqSiZgR2iJFODIkUzqJNyTKzuugUGrxx8Vvw
# QQuYAAoiAxDlDLH5zZI3Ge078eQ6tvlFEyZ1r7uq7z97dzvSxAKRPRkA0xdcOds/
# exgNRc2ThZYvXd9ZFk8/Ub3VRRg/7UqO6AZhdCMWtQ1QcydER38QXYkqa4UxFMTo
# qWpMgLxqeM+4f452cpkMnf7XkQgWoaNflTCCBfUwggPdoAMCAQICEB2iSDBvmyYY
# 0ILgln0z02owDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpOZXcgSmVyc2V5MRQwEgYDVQQHEwtKZXJzZXkgQ2l0eTEeMBwGA1UEChMVVGhl
# IFVTRVJUUlVTVCBOZXR3b3JrMS4wLAYDVQQDEyVVU0VSVHJ1c3QgUlNBIENlcnRp
# ZmljYXRpb24gQXV0aG9yaXR5MB4XDTE4MTEwMjAwMDAwMFoXDTMwMTIzMTIzNTk1
# OVowfDELMAkGA1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjEQ
# MA4GA1UEBxMHU2FsZm9yZDEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSQwIgYD
# VQQDExtTZWN0aWdvIFJTQSBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3DQEB
# AQUAA4IBDwAwggEKAoIBAQCGIo0yhXoYn0nwli9jCB4t3HyfFM/jJrYlZilAhlRG
# dDFixRDtsocnppnLlTDAVvWkdcapDlBipVGREGrgS2Ku/fD4GKyn/+4uMyD6DBmJ
# qGx7rQDDYaHcaWVtH24nlteXUYam9CflfGqLlR5bYNV+1xaSnAAvaPeX7Wpyvjg7
# Y96Pv25MQV0SIAhZ6DnNj9LWzwa0VwW2TqE+V2sfmLzEYtYbC43HZhtKn52BxHJA
# teJf7wtF/6POF6YtVbC3sLxUap28jVZTxvC6eVBJLPcDuf4vZTXyIuosB69G2flG
# HNyMfHEo8/6nxhTdVZFuihEN3wYklX0Pp6F8OtqGNWHTAgMBAAGjggFkMIIBYDAf
# BgNVHSMEGDAWgBRTeb9aqitKz1SA4dibwJ3ysgNmyzAdBgNVHQ4EFgQUDuE6qFM6
# MdWKvsG7rWcaA4WtNA4wDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQIMAYBAf8C
# AQAwHQYDVR0lBBYwFAYIKwYBBQUHAwMGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYE
# VR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20v
# VVNFUlRydXN0UlNBQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwdgYIKwYBBQUH
# AQEEajBoMD8GCCsGAQUFBzAChjNodHRwOi8vY3J0LnVzZXJ0cnVzdC5jb20vVVNF
# UlRydXN0UlNBQWRkVHJ1c3RDQS5jcnQwJQYIKwYBBQUHMAGGGWh0dHA6Ly9vY3Nw
# LnVzZXJ0cnVzdC5jb20wDQYJKoZIhvcNAQEMBQADggIBAE1jUO1HNEphpNveaiqM
# m/EAAB4dYns61zLC9rPgY7P7YQCImhttEAcET7646ol4IusPRuzzRl5ARokS9At3
# WpwqQTr81vTr5/cVlTPDoYMot94v5JT3hTODLUpASL+awk9KsY8k9LOBN9O3ZLCm
# I2pZaFJCX/8E6+F0ZXkI9amT3mtxQJmWunjxucjiwwgWsatjWsgVgG10Xkp1fqW4
# w2y1z99KeYdcx0BNYzX2MNPPtQoOCwR/oEuuu6Ol0IQAkz5TXTSlADVpbL6fICUQ
# DRn7UJBhvjmPeo5N9p8OHv4HURJmgyYZSJXOSsnBf/M6BZv5b9+If8AjntIeQ3pF
# McGcTanwWbJZGehqjSkEAnd8S0vNcL46slVaeD68u28DECV3FTSK+TbMQ5Lkuk/x
# YpMoJVcp+1EZx6ElQGqEV8aynbG8HArafGd+fS7pKEwYfsR7MUFxmksp7As9V1DS
# yt39ngVR5UR43QHesXWYDVQk/fBO4+L4g71yuss9Ou7wXheSaG3IYfmm8SoKC6W5
# 9J7umDIFhZ7r+YMp08Ysfb06dy6LN0KgaoLtO0qqlBCk4Q34F8W2WnkzGJLjtXX4
# oemOCiUe5B7xn1qHI/+fpFGe+zmAEc3btcSnqIBv5VPU4OOiwtJbGvoyJi1qV3Ac
# PKRYLqPzW0sH3DJZ84enGm1YMYICMzCCAi8CAQEwgZEwfDELMAkGA1UEBhMCR0Ix
# GzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4GA1UEBxMHU2FsZm9yZDEY
# MBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSQwIgYDVQQDExtTZWN0aWdvIFJTQSBD
# b2RlIFNpZ25pbmcgQ0ECEQDAJBgpJeq4KLMijoRVoV9eMAkGBSsOAwIaBQCgeDAY
# BgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3
# AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEW
# BBSj3WmYXIioiOXFGkxm06D+Qf60zjANBgkqhkiG9w0BAQEFAASCAQAmuvigOn/m
# pjteRRcHP+uiOx+JJseJ1K4d0cyl4be4of8yhQP/f7uO5NiJtIpiYIxKaYkOBT7I
# J/ujELvvdj8RHFB8yoy5DAn5O5TovGZOzI1RJ6xox6+gWke6Z/686S2f2LkcoRb5
# HeyURshqjII/r9PBkIUMsjiL+VonPWgFZN9RtB00xjYniOxGGMB6GX+r+JCWnpCE
# ZXAaNyD+dGaruY7gIcQ85GkMN5epvFu7YCGgycO+BDi/wYol0C1iXinl5xYAJBeY
# KtVmIAbAiUt1IExsKAnMEiWnMrZ1Znez8sc5n3ve99KLnASQtmBU2vXEu4XRXQAs
# iT0tcq0djphK
# SIG # End signature block
