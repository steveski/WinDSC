<#
.SYNOPSIS
    Exports IIS Website, WebApplication, and AppPool settings to screen, file, or JSON.

.DESCRIPTION
    This script reads deep IIS configuration properties for a designated Website, 
    its nested Web Applications, and their assigned Application Pools.
    
    It supports two modes:
    1. Raw Text Output: Dumps every single property found on the IIS COM Objects to screen and text file.
    2. JSON Export (-AsJson): Exports the configuration formatted into the MachineConfiguration.json schema pattern.

.PARAMETER SiteName
    The name of the IIS Website to export (e.g., "Site1").
    
.PARAMETER OutputFile
    Optional. The path to save the raw text dump or the JSON file. 
    (e.g., "C:\temp\Site1-Export.txt" or "C:\temp\Site1.json")

.PARAMETER AsJson
    Switch. If provided, exports the configuration as a structured JSON object mimicking MachineConfiguration.json.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SiteName,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [switch]$AsJson
)

if (-not (Get-Module -Name WebAdministration -ListAvailable)) {
    Write-Warning "WebAdministration module is not available. Please ensure IIS is installed."
    return
}
Import-Module WebAdministration

if (-not (Test-Path "IIS:\Sites\$SiteName")) {
    Write-Error "Website '$SiteName' does not exist in IIS."
    return
}

# --- Helper: Recursively extract ConfigurationElement properties into a Hashtable ---
function Get-DeepConfigurationAsHash {
    param ([object]$ConfigElement)
    
    $hash = @{}
    
    if ($null -eq $ConfigElement) { return $null }

    # Handle native types immediately
    if ($ConfigElement -is [string] -or $ConfigElement -is [int] -or $ConfigElement -is [bool]) {
        return $ConfigElement
    }

    # If it's a ConfigurationElement, it has Attributes and ChildElements (and sometimes Collections)
    if ($ConfigElement.GetType().Name -eq 'ConfigurationElement' -or $ConfigElement.GetType().Name -match 'ConfigurationSection') {
        
        # 1. Grab Attributes
        if ($ConfigElement.Attributes) {
            foreach ($attr in $ConfigElement.Attributes) {
                # Skip internal PS-specific metadata properties if possible, but keep raw IIS ones
                if ($attr.Name -match "^PS") { continue }
                $val = $attr.Value
                if ($null -ne $val) {
                    $hash[$attr.Name] = $val
                }
            }
        }

        # 2. Grab Child Elements recursively
        if ($ConfigElement.ChildElements) {
            foreach ($child in $ConfigElement.ChildElements) {
                if ($child.ItemXPath) {
                    $childName = $child.ElementTagName
                    $childHash = Get-DeepConfigurationAsHash -ConfigElement $child
                    if ($childHash.Count -gt 0) {
                        $hash[$childName] = $childHash
                    }
                }
            }
        }
        
        # 3. Handle Collections (like recycling schedules)
        if ($ConfigElement.Collection) {
            $colArray = @()
            foreach ($item in $ConfigElement.Collection) {
                $itemHash = Get-DeepConfigurationAsHash -ConfigElement $item
                if ($itemHash -and $itemHash.Count -gt 0) {
                    $colArray += $itemHash
                }
            }
            if ($colArray.Count -gt 0) {
                $hash["Collection"] = $colArray
            }
        }
    } else {
        # Fallback for standard PSObjects
        foreach ($prop in $ConfigElement.PSObject.Properties) {
            if ($prop.Name -match "^PS|ItemXPath|Attributes|ChildElements|ElementTagName|Methods|Schema") { continue }
            $val = $prop.Value
            if ($val -is [Microsoft.IIs.PowerShell.Framework.ConfigurationElement]) {
                $hash[$prop.Name] = Get-DeepConfigurationAsHash -ConfigElement $val
            } else {
                if ($null -ne $val) { $hash[$prop.Name] = $val }
            }
        }
    }
    
    return $hash
}

function Get-AppPoolInfo ($PoolName) {
    if (-not (Test-Path "IIS:\AppPools\$PoolName")) { return $null }
    
    $poolObj = Get-ItemProperty "IIS:\AppPools\$PoolName"
    $poolHash = Get-DeepConfigurationAsHash -ConfigElement $poolObj
    
    # Restructure for JSON schema if needed
    $formatted = @{
        Name = $PoolName
        ManagedRuntimeVersion = $poolObj.managedRuntimeVersion
        ManagedPipelineMode = $poolObj.managedPipelineMode
        AdvancedSettings = $poolHash
    }
    
    # Remove top level dupes from AdvancedSettings to keep it clean
    $formatted.AdvancedSettings.Remove("name")
    $formatted.AdvancedSettings.Remove("managedRuntimeVersion")
    $formatted.AdvancedSettings.Remove("managedPipelineMode")
    
    return [pscustomobject]$formatted
}


# --- 1. Gather Site Information ---
Write-Verbose "Gathering data for Website: $SiteName"
$siteObj = Get-ItemProperty "IIS:\Sites\$SiteName"
$siteHash = Get-DeepConfigurationAsHash -ConfigElement $siteObj

$bindingsArray = @()
foreach ($b in $siteObj.bindings.Collection) {
    $bindingsArray += @{
        Protocol = $b.protocol
        BindingInformation = $b.bindingInformation
    }
}

$siteFormatted = @{
    SiteName = $SiteName
    ContentPath = $siteObj.physicalPath
    AppPool = $siteObj.applicationPool
    Bindings = $bindingsArray
    AdvancedSettings = $siteHash
}
$siteFormatted.AdvancedSettings.Remove("name")
$siteFormatted.AdvancedSettings.Remove("physicalPath")
$siteFormatted.AdvancedSettings.Remove("applicationPool")
$siteFormatted.AdvancedSettings.Remove("bindings")


# --- 2. Gather Nested WebApplications ---
$webAppsPath = "IIS:\Sites\$SiteName"
$webApps = Get-ChildItem $webAppsPath | Where-Object { $_.NodeType -eq "application" }

$appsArray = @()
foreach ($app in $webApps) {
    $appName = $app.Name
    $appObj = Get-ItemProperty "$webAppsPath\$appName"
    $appHash = Get-DeepConfigurationAsHash -ConfigElement $appObj
    
    $appFormatted = @{
        Name = $appName
        ContentPath = $appObj.physicalPath
        AppPool = $appObj.applicationPool
        AdvancedSettings = $appHash
    }
    $appFormatted.AdvancedSettings.Remove("path")
    $appFormatted.AdvancedSettings.Remove("physicalPath")
    $appFormatted.AdvancedSettings.Remove("applicationPool")
    
    $appsArray += [pscustomobject]$appFormatted
}

if ($appsArray.Count -gt 0) {
    $siteFormatted["WebApps"] = $appsArray
}


# --- 3. Gather Associated AppPools ---
$associatedPools = @()
if ($siteFormatted.AppPool) { $associatedPools += $siteFormatted.AppPool }
foreach ($app in $appsArray) {
    if ($app.AppPool -and $associatedPools -notcontains $app.AppPool) {
         $associatedPools += $app.AppPool
    }
}

$poolsArray = @()
foreach ($p in $associatedPools) {
    $pInfo = Get-AppPoolInfo -PoolName $p
    if ($pInfo) { $poolsArray += $pInfo }
}


# --- Output Formatting ---
if ($AsJson) {
    # Structure roughly matching MachineConfiguration.json
    $jsonExport = @{
        TargetMachineNames = @($env:COMPUTERNAME)
        IISAppPools = $poolsArray
        IISWebSites = @($siteFormatted)
    }
    
    $output = $jsonExport | ConvertTo-Json -Depth 10
    
    Write-Host $output -ForegroundColor Cyan
    
    if ($OutputFile) {
        $output | Out-File -FilePath $OutputFile -Encoding utf8
        Write-Host "JSON exported to $OutputFile" -ForegroundColor Green
    }
} 
else {
    # Raw Text Dump Mode
    $output = "========================================================`n"
    $output += " IIS EXPORT: $SiteName `n"
    $output += "========================================================`n`n"
    
    $output += "---- WEBSITE TOP LEVEL ----`n"
    $output += ($siteFormatted | ConvertTo-Json -Depth 10)
    
    if ($appsArray.Count -gt 0) {
        $output += "`n`n---- NESTED WEB APPLICATIONS ----`n"
        $output += ($appsArray | ConvertTo-Json -Depth 10)
    }
    
    $output += "`n`n---- APPLICATION POOLS ----`n"
    $output += ($poolsArray | ConvertTo-Json -Depth 10)
    
    Write-Host $output -ForegroundColor Cyan
    
    if ($OutputFile) {
        $output | Out-File -FilePath $OutputFile -Encoding utf8
        Write-Host "Raw Text exported to $OutputFile" -ForegroundColor Green
    }
}
