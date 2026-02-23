<#
.SYNOPSIS
    Ensures specific Windows Server Features are enabled or disabled.

.DESCRIPTION
    Checks the installation state of specified Windows Server Features.
    If a feature should be enabled and is not, it is installed.
    If a feature should be disabled and is, it is uninstalled.

.PARAMETER Config
    A hashtable or custom object containing 'EnabledFeatures' and 'DisabledFeatures' arrays.
    Expected structure:
    {
        "EnabledFeatures": [ "Web-Static-Content" ],
        "DisabledFeatures": [ "DHCP" ]
    }
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

if (-not (Get-Module -Name ServerManager -ListAvailable)) {
    Write-Warning "ServerManager module is not available. Ensure-Server-Features cannot run. This is expected if not running on Windows Server."
    return
}
Import-Module ServerManager -ErrorAction SilentlyContinue

# Ensure we have arrays
$enabled = if ($Config.EnabledFeatures) { @($Config.EnabledFeatures) } else { @() }
$disabled = if ($Config.DisabledFeatures) { @($Config.DisabledFeatures) } else { @() }

# Process Enabled Features
foreach ($feature in $enabled) {
    if ([string]::IsNullOrWhiteSpace($feature)) { continue }
    
    try {
        $state = Get-WindowsFeature -Name $feature -ErrorAction Stop
        if ($state.InstallState -ne "Installed") {
            Write-Verbose "Enabling Feature: $feature"
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
            Write-Host "Enabled Feature: $feature" -ForegroundColor Green
        } else {
            Write-Verbose "Feature already enabled: $feature"
        }
    } catch {
        Write-Warning "Could not process or enable feature '$feature'. It may not exist. Error: $_"
    }
}

# Process Disabled Features
foreach ($feature in $disabled) {
    if ([string]::IsNullOrWhiteSpace($feature)) { continue }

    try {
        $state = Get-WindowsFeature -Name $feature -ErrorAction Stop
        if ($state.InstallState -eq "Installed") {
            Write-Verbose "Disabling Feature: $feature"
            Uninstall-WindowsFeature -Name $feature -Remove | Out-Null
            Write-Host "Disabled Feature: $feature" -ForegroundColor DarkYellow
        } else {
            Write-Verbose "Feature already disabled: $feature"
        }
    } catch {
         Write-Warning "Could not process or disable feature '$feature'. It may not exist. Error: $_"
    }
}
