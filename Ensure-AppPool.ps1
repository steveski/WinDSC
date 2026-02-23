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
    # Helper to deeply resolve JSON PSCustomObjects to Hashtables
    function Convert-ToHashtable {
        param([Parameter(Mandatory=$true)] [AllowNull()] $Obj)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [array]) {
            $arr = @()
            foreach ($item in $Obj) { $arr += Convert-ToHashtable -Obj $item }
            return $arr
        } elseif ($Obj -is [System.Management.Automation.PSCustomObject]) {
            $hash = @{}
            foreach ($prop in $Obj.PSObject.Properties) {
                $hash[$prop.Name] = Convert-ToHashtable -Obj $prop.Value
            }
            return $hash
        }
        return $Obj
    }

    foreach ($property in $advSettings.PSObject.Properties) {
        $propName = $property.Name
        $propValue = Convert-ToHashtable -Obj $property.Value

        # Skip empty properties
        if (-not [string]::IsNullOrWhiteSpace($propName)) {
            Write-Verbose "Dynamically setting advanced property '$propName' to on AppPool '$poolName'"
            try {
                if ($propValue -is [hashtable] -or $propValue -is [array]) {
                    # For collections like recycling schedules, Set-ItemProperty expects the hashtable/array directly.
                    # Note: We append @{...} or @(...) and let the IIS provider handle it natively, but sometimes it requires clearing first
                    Clear-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -ErrorAction SilentlyContinue
                    Set-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -Value $propValue
                } else {
                    Set-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -Value $propValue
                }
            } catch {
                Write-Warning "Failed to set property '$propName' on AppPool '$poolName'. Error: $_"
            }
        }
    }
}
