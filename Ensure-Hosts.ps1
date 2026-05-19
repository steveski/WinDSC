<#
.SYNOPSIS
    Ensures specific IP to Hostname mappings exist in the Windows hosts file.

.DESCRIPTION
    Reads the %windir%\system32\drivers\etc\hosts file. If the specified hostname
    is found, its IP address is updated if it differs. If not found, a new entry
    is appended. No entries are removed.

.PARAMETER Config
    A hashtable or custom object containing a 'Hosts' array.
    Expected structure of an item:
    {
        "IPAddress": "127.0.0.1",
        "HostName": "site1.local"
    }
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

$hostsFilePath = "$env:windir\System32\drivers\etc\hosts"

# We must run elevated to write to the hosts file
if (-not (Test-Path $hostsFilePath)) {
    Write-Warning "Hosts file not found at $hostsFilePath"
    return
}

$hostsArray = if ($Config.Hosts -is [array]) { $Config.Hosts } else { @($Config.Hosts) }

if ($hostsArray.Count -gt 0) {
    foreach ($hostConfig in $hostsArray) {
        $hostname = $hostConfig.HostName
        $ip = $hostConfig.IpAddress
        $ensure = if ($hostConfig.Ensure) { $hostConfig.Ensure } else { "Present" }

        if (-not $hostname) {
            Write-Warning "Invalid host entry found. HostName missing. Skipping."
            continue
        }

        # Read the current contents of the hosts file
        $hostsContent = Get-Content -Path $hostsFilePath
        $matchFound = $false
        $contentModified = $false
        $newContent = @()

        foreach ($line in $hostsContent) {
            $actualLine = $line
            $commentIndex = $line.IndexOf('#')
            if ($commentIndex -ge 0) {
                $actualLine = $line.Substring(0, $commentIndex)
            }
            
            $parts = $actualLine -split '\s+' | Where-Object { $_ -ne '' }
            $lineKept = $true

            if ($parts.Count -ge 2) {
                $lineIp = $parts[0]
                $lineHostNames = $parts[1..($parts.Count - 1)]
                
                if ($lineHostNames -contains $hostname) {
                    $matchFound = $true
                    
                    if ($ensure -eq "Absent") {
                        Write-Host "Removing explicit host entry: $hostname" -ForegroundColor DarkYellow
                        
                        $keptHostNames = $lineHostNames | Where-Object { $_ -ne $hostname }
                        if ($keptHostNames.Count -eq 0) {
                            $lineKept = $false
                        } else {
                            $replacementLine = "$lineIp"
                            foreach ($name in $keptHostNames) {
                                $replacementLine += "`t$name"
                            }
                            if ($commentIndex -ge 0) {
                                 $replacementLine += "`t" + $line.Substring($commentIndex)
                            }
                            $newContent += $replacementLine
                            $lineKept = $false
                        }
                        $contentModified = $true
                    } elseif ($lineIp -ne $ip) {
                        Write-Verbose "Updating IP for $hostname from $lineIp to $ip"
                        $replacementLine = "$ip"
                        foreach ($name in $lineHostNames) {
                            $replacementLine += "`t$name"
                        }
                        if ($commentIndex -ge 0) {
                             $replacementLine += "`t" + $line.Substring($commentIndex)
                        }
                        $newContent += $replacementLine
                        $lineKept = $false
                        $contentModified = $true
                    }
                }
            }
            
            if ($lineKept) {
                $newContent += $line
            }
        }

        if (-not $matchFound -and $ensure -eq "Present") {
            if (-not $ip) {
                Write-Warning "Cannot add host entry for '$hostname'. IP address is missing."
                continue
            }
            Write-Verbose "Hostname '$hostname' not found. Appending to hosts file."
            $newContent += "$ip`t$hostname"
            $contentModified = $true
        }

        if ($contentModified) {
            try {
                $newContent | Set-Content -Path $hostsFilePath -Force
                Write-Verbose "Hosts file updated successfully for $hostname."
            } catch {
                Write-Error "Failed to update hosts file. Ensure script is running as Administrator. Error: $_"
            }
        } else {
            Write-Verbose "Host entry for $hostname is already in the desired state."
        }
    }
}
