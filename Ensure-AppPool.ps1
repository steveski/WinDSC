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
    # Convert CustomObject to a Hashtable to easily iterate properties if needed, 
    # or use PSMemberInfo
    foreach ($property in $advSettings.PSObject.Properties) {
        $propName = $property.Name
        $propValue = $property.Value

        # Skip empty properties or system properties that might be injected by PowerShell
        if (-not [string]::IsNullOrWhiteSpace($propName)) {
            Write-Verbose "Dynamically setting advanced property '$propName' to '$propValue' on AppPool '$poolName'"
            try {
                # Read current value to be idempotent if possible, though Set-ItemProperty is generally safe to reapply
                $currentValue = Get-ItemProperty -Path "IIS:\AppPools\$poolName" -Name $propName -ErrorAction SilentlyContinue
                if ($currentValue.Item($propName) -ne $propValue -and $currentValue.$propName -ne $propValue) {
                    Set-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -Value $propValue
                }
            } catch {
                Write-Warning "Failed to set property '$propName' on AppPool '$poolName'. Ensure the property name exactly matches the IIS Schema. Error: $_"
            }
        }
    }
}
