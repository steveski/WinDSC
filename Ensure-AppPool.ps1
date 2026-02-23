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
            $baseFilter = "system.applicationHost/applicationPools/add[@name='$poolName']"
            try {
                if ($propValue -is [hashtable] -or $propValue -is [array]) {
                    Write-Verbose "Dynamically setting collection property '$propName' on AppPool '$poolName'"
                    $collectionFilter = "$baseFilter/$($propName -replace '\.', '/')"
                    
                    # Clear existing collection (e.g., old schedules)
                    Clear-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $collectionFilter -ErrorAction SilentlyContinue
                    
                    # Add new items
                    $values = if ($propValue -is [array]) { $propValue } else { @($propValue) }
                    foreach ($val in $values) {
                        Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $collectionFilter -Name "." -Value $val -ErrorAction Stop
                    }
                } else {
                    Write-Verbose "Dynamically setting advanced property '$propName' to '$propValue' on AppPool '$poolName'"
                    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Filter $baseFilter -Name $propName -Value $propValue -ErrorAction Stop
                }
            } catch {
                Write-Warning "Failed to set property '$propName' on AppPool '$poolName'. Error: $_"
            }
        }
    }
}
