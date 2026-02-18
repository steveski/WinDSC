<#
.SYNOPSIS
    Ensures an IIS Application Pool exists with specified settings.

.PARAMETER Config
    A hashtable or custom object containing the App Pool configuration.
    Expected structure:
    {
        "Name": "Pool1",
        "ManagedRuntimeVersion": "v4.0",
        "ManagedPipelineMode": "Integrated",
        "AdvancancedSettings": { "StartMode": "AlwaysRunning" } 
        # Note: Typo 'AdvancancedSettings' in source JSON is handled.
    }
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

Import-Module WebAdministration -ErrorAction SilentlyContinue

$poolName = $Config.Name
Write-Verbose "Ensuring AppPool: $poolName"

# 1. Ensure AppPool Exists
if (-not (Test-Path "IIS:\AppPools\$poolName")) {
    Write-Verbose "AppPool does not exist. Creating: $poolName"
    New-WebAppPool -Name $poolName
}

# 2. Set Basic Settings
$pool = Get-Item "IIS:\AppPools\$poolName"
$changes = $false

if ($pool.managedRuntimeVersion -ne $Config.ManagedRuntimeVersion) {
    Write-Verbose "Setting managedRuntimeVersion to $($Config.ManagedRuntimeVersion)"
    $pool.managedRuntimeVersion = $Config.ManagedRuntimeVersion
    $changes = $true
}

if ($pool.managedPipelineMode -ne $Config.ManagedPipelineMode) {
    Write-Verbose "Setting managedPipelineMode to $($Config.ManagedPipelineMode)"
    $pool.managedPipelineMode = $Config.ManagedPipelineMode
    $changes = $true
}

if ($changes) {
    $pool | Set-Item
}

# 3. Handle Advanced Settings (typographical robustness included)
$advSettings = $null
if ($Config.AdvancedSettings) { $advSettings = $Config.AdvancedSettings }
elseif ($Config.AdvancancedSettings) { $advSettings = $Config.AdvancancedSettings }

if ($advSettings) {
    # StartMode is a property of processModel
    if ($advSettings.StartMode) {
        $currentStartMode = $pool.processModel.startMode
        if ($currentStartMode -ne $advSettings.StartMode) {
             Write-Verbose "Setting startMode to $($advSettings.StartMode)"
             Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel.startMode -Value $advSettings.StartMode
        }
    }
    
    # Handle other potential advanced settings if needed (extensible here)
    # The JSON schema currently only shows StartMode.
}
