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
            
            # Auto-correct PascalCase to camelCase for the IIS provider
            # e.g. "StartMode" -> "startMode", "ProcessModel.idleTimeout" -> "processModel.idleTimeout"
            if ($propName[0] -cmatch '[A-Z]') {
                $propName = [char]::ToLower($propName[0]) + $propName.Substring(1)
            }

            Write-Verbose "Dynamically setting advanced property '$propName' on AppPool '$poolName'"
            try {
                if ($propName -match "/") {
                    # It's an explicit WebConfiguration path (like system.applicationHost/applicationPools/...)
                    $lastDotIndex = $propName.LastIndexOf('.')
                    if ($lastDotIndex -gt -1) {
                        $filter = $propName.Substring(0, $lastDotIndex)
                        $name = $propName.Substring($lastDotIndex + 1)
                        Set-WebConfigurationProperty -PSPath "IIS:\" -Filter "$filter[@name='$poolName']" -Name $name -Value $propValue -ErrorAction Stop
                    } else {
                        Write-Warning "WebConfiguration property '$propName' must contain a dot separator for the property name."
                    }
                } else {
                    Set-ItemProperty "IIS:\AppPools\$poolName" -Name $propName -Value $propValue -ErrorAction Stop
                }
                Write-Host "Set $propName on $poolName successfully" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to set property '$propName' on AppPool '$poolName'. Check property spelling/casing! Error: $_"
            }
        }
    }
}
