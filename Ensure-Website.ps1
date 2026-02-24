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
# Strategy: Add missing bindings and remove extra bindings not in config
$existingBindings = Get-WebBinding -Name $siteName

# Keep track of which bindings should exist based on config
$desiredBindings = @()

foreach ($binding in $Config.Bindings) {
    if ($binding -is [System.Management.Automation.PSCustomObject]) {
        # if it's a parsed object from JSON
        $protocol = $binding.Protocol
        $port = $binding.Port
        $hostHeader = $binding.HostHeader
    } else {
        # if it's a hashtable
        $protocol = $binding["Protocol"]
        $port = $binding["Port"]
        $hostHeader = $binding["HostHeader"]
    }

    if (-not $hostHeader) { $hostHeader = "" }
    
    # Store a normalized form to compare later
    $bindingInfo = "$protocol`:$port`:$hostHeader"
    $desiredBindings += $bindingInfo

    # Check if binding exists
    if ($protocol -and $port) {
        $exists = Get-WebBinding -Name $siteName -Protocol $protocol -Port $port -HostHeader $hostHeader
        if (-not $exists) {
            Write-Verbose ("Adding Binding: {0} {1}:{2}" -f $protocol, $hostHeader, $port)
            if ([string]::IsNullOrWhiteSpace($hostHeader)) {
                New-WebBinding -Name $siteName -Protocol $protocol -Port $port -IPAddress "*"
            } else {
                New-WebBinding -Name $siteName -Protocol $protocol -Port $port -HostHeader $hostHeader -IPAddress "*"
            }
        }
    }
}

# Now evaluate existing bindings to see if any should be removed
if ($existingBindings) {
    foreach ($exBind in $existingBindings) {
        # IIS module returns bindings with bindingInformation like "IP:Port:HostHeader"
        # Since IP might be * (or blank in IIS Manager which is * anyway), parse it out.
        $exBindInfoParts = $exBind.bindingInformation -split ":"
        $exPort = $exBindInfoParts[1]
        $exHostHeader = $exBindInfoParts[2]
        $exProtocol = $exBind.protocol

        if (-not $exHostHeader) { $exHostHeader = "" }
        if (-not $exPort) { $exPort = 80 } # Fallback port

        $exBindingKey = "$exProtocol`:$exPort`:$exHostHeader"

        # Check if the existing binding was in our desired list
        $found = $false
        foreach ($des in $desiredBindings) {
            # Simple case-insensitive match
            if ($des -eq $exBindingKey) {
                $found = $true
                break
            }
        }

        # If it wasn't in the config, remove it
        if (-not $found) {
            Write-Verbose ("Removing unspecified Binding: {0} {1}:{2}" -f $exProtocol, $exHostHeader, $exPort)
            Remove-WebBinding -Name $siteName -Protocol $exProtocol -Port $exPort -HostHeader $exHostHeader
        }
    }
}

if ($Config.AdvancedSettings) {
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

    # JSON might have AdvancedSettings as an array of objects or a single object.
    $advList = if ($Config.AdvancedSettings -is [array]) { $Config.AdvancedSettings } else { @($Config.AdvancedSettings) }

    foreach ($adv in $advList) {
        if ($adv) {
            foreach ($property in $adv.PSObject.Properties) {
                $propName = $property.Name
                $propValue = Convert-ToHashtable -Obj $property.Value
                
                if (-not [string]::IsNullOrWhiteSpace($propName)) {
                    
                    # Auto-correct PascalCase to camelCase for the IIS provider
                    if ($propName[0] -cmatch '[A-Z]') {
                        $propName = [char]::ToLower($propName[0]) + $propName.Substring(1)
                    }

                    # Some common "website" properties actually live under virtualDirectoryDefaults or applicationDefaults
                    if ($propName -match "^physicalPathCredential") {
                        $propName = "virtualDirectoryDefaults.$propName"
                    } elseif ($propName -match "^preloadEnabled") {
                        $propName = "applicationDefaults.$propName"
                    }

                    Write-Verbose "Dynamically setting advanced property '$propName' on Site '$siteName'"
                    try {
                        if ($propName -match "/") {
                            # It's an explicit WebConfiguration path (like system.webServer/security/authentication/...)
                            $lastDotIndex = $propName.LastIndexOf('.')
                            if ($lastDotIndex -gt -1) {
                                $filter = $propName.Substring(0, $lastDotIndex)
                                $name = $propName.Substring($lastDotIndex + 1)
                                Set-WebConfigurationProperty -PSPath "IIS:\" -Location $siteName -Filter $filter -Name $name -Value $propValue -ErrorAction Stop
                            } else {
                                Write-Warning "WebConfiguration property '$propName' must contain a dot separator for the property name."
                            }
                        } else {
                            # It's a standard IIS Site item property
                            Set-ItemProperty "IIS:\Sites\$siteName" -Name $propName -Value $propValue -ErrorAction Stop
                        }
                        Write-Host "Set $propName on $siteName successfully" -ForegroundColor Green
                    } catch {
                        Write-Warning "Failed to set property '$propName' on Site '$siteName'. Check property spelling/casing! Error: $_"
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

        # Handle Advanced Settings for WebApp
        if ($appConfig.AdvancedSettings) {
            $appAdvList = if ($appConfig.AdvancedSettings -is [array]) { $appConfig.AdvancedSettings } else { @($appConfig.AdvancedSettings) }
            
            foreach ($appAdv in $appAdvList) {
                if ($appAdv) {
                    foreach ($property in $appAdv.PSObject.Properties) {
                        $propName = $property.Name
                        $propValue = Convert-ToHashtable -Obj $property.Value
                        
                        if (-not [string]::IsNullOrWhiteSpace($propName)) {
                            
                            # Auto-correct PascalCase to camelCase for the IIS provider
                            if ($propName[0] -cmatch '[A-Z]') {
                                $propName = [char]::ToLower($propName[0]) + $propName.Substring(1)
                            }
        
                            # Some common "website" properties actually live under virtualDirectoryDefaults or applicationDefaults
                            if ($propName -match "^physicalPathCredential") {
                                $propName = "virtualDirectoryDefaults.$propName"
                            } elseif ($propName -match "^preloadEnabled") {
                                $propName = "applicationDefaults.$propName"
                            }
        
                            Write-Verbose "Dynamically setting advanced property '$propName' on WebApp '$appName'"
                            try {
                                if ($propName -match "/") {
                                    # It's an explicit WebConfiguration path
                                    $lastDotIndex = $propName.LastIndexOf('.')
                                    if ($lastDotIndex -gt -1) {
                                        $filter = $propName.Substring(0, $lastDotIndex)
                                        $name = $propName.Substring($lastDotIndex + 1)
                                        # Use Location "$siteName/$appName" for nested apps
                                        Set-WebConfigurationProperty -PSPath "IIS:\" -Location "$siteName/$appName" -Filter $filter -Name $name -Value $propValue -ErrorAction Stop
                                    } else {
                                        Write-Warning "WebConfiguration property '$propName' must contain a dot separator for the property name."
                                    }
                                } else {
                                    # It's a standard IIS Site item property - Use $fullPath for nested apps
                                    Set-ItemProperty $fullPath -Name $propName -Value $propValue -ErrorAction Stop
                                }
                                Write-Host "Set $propName on $appName successfully" -ForegroundColor Green
                            } catch {
                                Write-Warning "Failed to set property '$propName' on WebApp '$appName'. Check property spelling/casing! Error: $_"
                            }
                        }
                    }
                }
            }
        }
    }
}
