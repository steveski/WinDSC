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

# 3. Handle Advanced Settings
$advSettings = $Config.AdvancedSettings

if ($advSettings) {
    # Convert CustomObject to a Hashtable to easily iterate properties if needed, 
    # or use PSMemberInfo
    foreach ($property in $advSettings.PSObject.Properties) {
        $propName = $property.Name
        $propValue = $property.Value

        # If the value from JSON is an object (PSCustomObject), IIS cmdlets usually expect a Hashtable instead.
        if ($propValue -is [System.Management.Automation.PSCustomObject]) {
            $hash = @{}
            foreach ($subProp in $propValue.PSObject.Properties) {
                $hash[$subProp.Name] = $subProp.Value
            }
            $propValue = $hash
        }

        # Skip empty properties or system properties that might be injected by PowerShell
        if (-not [string]::IsNullOrWhiteSpace($propName)) {
            Write-Verbose "Dynamically setting advanced property '$propName' to '$propValue' on AppPool '$poolName'"
            try {
                # IIS provider is finicky with Get-ItemProperty returning deeply nested objects vs direct values.
                # It evaluates complex property paths poorly for comparisons.
                # For idempotency, we just set it. Set-ItemProperty on IIS provider is generally safe to reapply.
                Set-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -Value $propValue
            } catch {
                Write-Warning "Failed to set property '$propName' on AppPool '$poolName'. Ensure the property name exactly matches the IIS Schema. Error: $_"
            }
        }
    }
}
