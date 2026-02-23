<#
.SYNOPSIS
    Ensures an IIS Website and its Web Applications exist with specified settings.

.PARAMETER Config
    A hashtable or custom object containing the Website configuration.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

Import-Module WebAdministration -ErrorAction SilentlyContinue

$siteName = $Config.SiteName
Write-Verbose "Ensuring Website: $siteName"

# 1. Ensure Website Exists
if (-not (Test-Path "IIS:\Sites\$siteName")) {
    Write-Verbose "Website does not exist. Creating: $siteName"
    
    # Needs at least one binding to create. Use the first one from config.
    $firstBinding = $Config.Bindings[0]
    $port = if ($firstBinding.Port) { $firstBinding.Port } else { 80 }
    $protocol = if ($firstBinding.Protocol) { $firstBinding.Protocol } else { "http" }
    $hostHeader = if ($firstBinding.HostHeader) { $firstBinding.HostHeader } else { "*" }

    # Ensure content path directory exists first (though Ensure-Directory should have run, duplication for safety)
    if (-not (Test-Path $Config.ContentPath)) { New-Item -Path $Config.ContentPath -ItemType Directory -Force | Out-Null }

    New-Website -Name $siteName -Port $port -IPAddress "*" -HostHeader $hostHeader -PhysicalPath $Config.ContentPath -ApplicationPool $Config.AppPool -Force
} else {
    # Update Physical Path if changed
    $site = Get-Item "IIS:\Sites\$siteName"
    if ($site.physicalPath -ne $Config.ContentPath) {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $Config.ContentPath
        Write-Verbose "Updated PhysicalPath for $siteName"
    }
    
    # Update AppPool if changed
    if ($site.applicationPool -ne $Config.AppPool) {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $Config.AppPool
        Write-Verbose "Updated AppPool for $siteName"
    }
}

# 2. Ensure Bindings
# Strategy: Add missing bindings. (Optional: Remove extra bindings if strict equality desired, but usually dangerous)
foreach ($binding in $Config.Bindings) {
    $protocol = $binding.Protocol
    $port = $binding.Port
    $hostHeader = $binding.HostHeader
    if (-not $hostHeader) { $hostHeader = "" }

    # Check if binding exists
    $exists = Get-WebBinding -Name $siteName -Protocol $protocol -Port $port -HostHeader $hostHeader
    if (-not $exists) {
        Write-Verbose ("Adding Binding: {0} {1}:{2}" -f $protocol, $hostHeader, $port)
        New-WebBinding -Name $siteName -Protocol $protocol -Port $port -HostHeader $hostHeader
    }
}

if ($Config.AdvancedSettings) {
    # JSON might have AdvancedSettings as an array of objects or a single object.
    $advList = if ($Config.AdvancedSettings -is [array]) { $Config.AdvancedSettings } else { @($Config.AdvancedSettings) }

    foreach ($adv in $advList) {
        if ($adv) {
            foreach ($property in $adv.PSObject.Properties) {
                $propName = $property.Name
                $propValue = $property.Value
                
                if (-not [string]::IsNullOrWhiteSpace($propName)) {
                    Write-Verbose "Dynamically setting advanced property '$propName' to '$propValue' on Site '$siteName'"
                    try {
                        # IIS provider is finicky with Get-ItemProperty returning deeply nested objects vs direct values.
                        # For idempotency, we just set it. Set-ItemProperty on IIS provider is generally safe to reapply.
                        Set-ItemProperty "IIS:\Sites\$siteName" -Name $propName -Value $propValue
                    } catch {
                        Write-Warning "Failed to set property '$propName' on Site '$siteName'. Ensure the property path matches IIS Schema (e.g., 'virtualDirectoryDefaults.userName'). Error: $_"
                    }
                }
            }
        }
    }
}

# 4. Web Applications
if ($Config.WebApps) {
    foreach ($appConfig in $Config.WebApps) {
        $appName = $appConfig.Name
        $appPath = "/$appName" # IIS Path format
        $fullPath = "IIS:\Sites\$siteName$appPath"
        
        Write-Verbose "Ensuring WebApp: $appName on $siteName"

        if (-not (Test-Path $appConfig.ContentPath)) { New-Item -Path $appConfig.ContentPath -ItemType Directory -Force | Out-Null }

        if (-not (Test-Path $fullPath)) {
            Write-Verbose "Creating WebApp $appName"
            New-WebApplication -Name $appName -Site $siteName -PhysicalPath $appConfig.ContentPath -ApplicationPool $appConfig.AppPool
        } else {
            # Update properties
            $app = Get-Item $fullPath
            if ($app.physicalPath -ne $appConfig.ContentPath) {
                 Set-ItemProperty $fullPath -Name physicalPath -Value $appConfig.ContentPath
            }
             if ($app.applicationPool -ne $appConfig.AppPool) {
                 Set-ItemProperty $fullPath -Name applicationPool -Value $appConfig.AppPool
            }
        }
    }
}
