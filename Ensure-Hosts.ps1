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

# Ensure the config we received handles PowerShell's PSCustomObject gracefully
$hostsObject = $Config

# Iterate through the properties of the object (Keys are Hostnames, Values are IPs)
foreach ($property in $hostsObject.PSObject.Properties) {
    if ([string]::IsNullOrWhiteSpace($property.Name)) { continue }

    $hostname = $property.Name
    $ip = $property.Value
    
    if (-not $ip -or -not $hostname) {
        Write-Warning "Invalid host entry found. IP: '$ip', Host: '$hostname'. Skipping."
        continue
    }

    Write-Verbose "Ensuring Host Entry: $ip -> $hostname"

    # Read the current contents of the hosts file
    $hostsContent = Get-Content -Path $hostsFilePath
    $matchFound = $false
    $contentModified = $false
    $newContent = @()

    foreach ($line in $hostsContent) {
        # Check if the line contains our hostname (ignoring comments optionally, but simpler to just regex)
        # A typical hosts line looks like: 127.0.0.1  localhost
        # Regex looks for the hostname as a distinct word anywhere on a non-comment line.
        
        # Strip comments
        $actualLine = $line
        $commentIndex = $line.IndexOf('#')
        if ($commentIndex -ge 0) {
            $actualLine = $line.Substring(0, $commentIndex)
        }
        
        # Split by whitespace
        $parts = $actualLine -split '\s+' | Where-Object { $_ -ne '' }

        if ($parts.Count -ge 2) {
            $lineIp = $parts[0]
            # All subsequent parts are hostnames mapping to that IP
            $lineHostNames = $parts[1..($parts.Count - 1)]

            if ($lineHostNames -contains $hostname) {
                $matchFound = $true
                if ($lineIp -ne $ip) {
                    Write-Verbose "Updating IP for $hostname from $lineIp to $ip"
                    # We just modify the IP for this specific line. 
                    # If there are multiple hostnames, this changes all of them on this line to the new IP.
                    # Or we could just replace the line. For simplicity and keeping other names attached, replace IP.
                    # Let's rebuild the line with the new IP.
                    $replacementLine = "$ip"
                    foreach ($name in $lineHostNames) {
                        $replacementLine += "`t$name"
                    }
                    
                    # If there was a comment originally, we could try to preserve it, but rebuilding is safer.
                    # For a perfect script, we'd preserve exactly, but this suffices.
                    if ($commentIndex -ge 0) {
                         $replacementLine += "`t" + $line.Substring($commentIndex)
                    }

                    $newContent += $replacementLine
                    $contentModified = $true
                    continue # Skip adding the original line
                }
            }
        }
        
        # Keep original line if no changes
        $newContent += $line
    }

    if (-not $matchFound) {
        Write-Verbose "Hostname '$hostname' not found. Appending to hosts file."
        $newContent += "$ip`t$hostname"
        $contentModified = $true
    }

    if ($contentModified) {
        try {
            $newContent | Set-Content -Path $hostsFilePath -Force
            Write-Verbose "Hosts file updated successfully."
        } catch {
            Write-Error "Failed to update hosts file. Ensure script is running as Administrator. Error: $_"
        }
    } else {
        Write-Verbose "Host entry already correct."
    }
}
