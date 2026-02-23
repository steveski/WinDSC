<#
.SYNOPSIS
    Applies IIS Desired State Configuration based on a JSON configuration file.

.DESCRIPTION
    This script reads a JSON configuration file, identifies the configuration block
    targeted for the current machine, and applies the settings for Directories,
    AppPools, and Websites using helper scripts.

.PARAMETER ConfigurationPath
    Path to the JSON configuration file. Defaults to '.\MachineConfiguration.json'.

.PARAMETER Help
    Displays usage information.

.EXAMPLE
    .\Apply-IISConfiguration.ps1 -ConfigurationPath ".\MyConfig.json"
#>
[CmdletBinding()]
param (
    [string]$ConfigurationPath = ".\MachineConfiguration.json",
    [switch]$Help
)

function Show-Usage {
    Write-Host "Usage: .\Apply-IISConfiguration.ps1 [-ConfigurationPath <path>] [-Help]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -ConfigurationPath  Path to the JSON configuration file. Default: .\MachineConfiguration.json"
    Write-Host "  -Help               Show this usage message."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\Apply-IISConfiguration.ps1"
    Write-Host "  .\Apply-IISConfiguration.ps1 -ConfigurationPath .\Config\Prod.json"
}

if ($Help) {
    Show-Usage
    exit
}

$ErrorActionPreference = "Stop"

# Validate Configuration File
if (-not (Test-Path $ConfigurationPath)) {
    Write-Error "Configuration file not found at: $ConfigurationPath"
    Show-Usage
    exit 1
}

try {
    $jsonContent = Get-Content -Path $ConfigurationPath -Raw
    $configData = $jsonContent | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse JSON configuration file: $_"
    exit 1
}

$currentMachine = $env:COMPUTERNAME
Write-Host "Running configuration for machine: $currentMachine" -ForegroundColor Cyan

# Ensure WebAdministration module is loaded
if (-not (Get-Module -Name WebAdministration -ListAvailable)) {
    Write-Warning "WebAdministration module is not installed. IIS configuration cannot proceed."
    # proceed to try anyway, likely fail on helpers
} else {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
}

$matchFound = $false

foreach ($configBlock in $configData) {
    if ($configBlock.TargetMachineNames -contains $currentMachine) {
        $matchFound = $true
        Write-Host "Found configuration for $currentMachine" -ForegroundColor Green

        # 0. Set TimeZone
        if ($configBlock.TimeZone) {
            Write-Host "Checking TimeZone..." -ForegroundColor Cyan
            $currentTimeZone = (Get-TimeZone).Id
            if ($currentTimeZone -ne $configBlock.TimeZone) {
                try {
                    Write-Verbose "Changing TimeZone from '$currentTimeZone' to '$($configBlock.TimeZone)'"
                    Set-TimeZone -Id $configBlock.TimeZone -ErrorAction Stop
                    Write-Host "Set TimeZone to: $($configBlock.TimeZone)" -ForegroundColor Green
                } catch {
                    Write-Error "Failed to set TimeZone to '$($configBlock.TimeZone)'. Ensure the ID is valid and script runs as Administrator. Error: $_"
                }
            } else {
                Write-Verbose "TimeZone is already '$currentTimeZone'."
            }
        }

        # 0.5. Apply Windows Server Features
        if ($configBlock.EnabledFeatures -or $configBlock.DisabledFeatures) {
            Write-Host "Processing Windows Server Features..." -ForegroundColor Cyan
            .\Ensure-Server-Features.ps1 -Config $configBlock
        }

        # 1. Apply Directories
        if ($configBlock.Directories) {
            Write-Host "Processing Directories..." -ForegroundColor Cyan
            foreach ($dir in $configBlock.Directories) {
                .\Ensure-Directory.ps1 -Config $dir
            }
        }

        # 2. Apply AppPools
        if ($configBlock.IISAppPools) {
            Write-Host "Processing AppPools..." -ForegroundColor Cyan
            foreach ($pool in $configBlock.IISAppPools) {
                .\Ensure-AppPool.ps1 -Config $pool
            }
        }

        # 3. Apply WebSites
        if ($configBlock.IISWebSites) {
             Write-Host "Processing WebSites..." -ForegroundColor Cyan
            foreach ($site in $configBlock.IISWebSites) {
                .\Ensure-Website.ps1 -Config $site
            }
        }

        # 4. Apply Hosts file entries
        if ($configBlock.Hosts) {
            Write-Host "Processing Hosts file entries..." -ForegroundColor Cyan
            .\Ensure-Hosts.ps1 -Config $configBlock.Hosts
        }

        # 5. Apply Event Logs
        if ($configBlock.EventLogs) {
            Write-Host "Processing Event Logs..." -ForegroundColor Cyan
            .\Ensure-EventLog.ps1 -Config $configBlock.EventLogs
        }
    }
}

if (-not $matchFound) {
    Write-Warning "No configuration found for machine: $currentMachine in $ConfigurationPath"
} else {
    Write-Host "Configuration applied successfully." -ForegroundColor Green
}
