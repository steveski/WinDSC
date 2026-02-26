<#
.SYNOPSIS
    Ensures a directory exists with specified attributes, permissions, and share settings.

.DESCRIPTION
    This script is designed to be idempotent. It checks the current state of the directory
    and applies changes only if necessary.

.PARAMETER Config
    A hashtable or custom object containing the directory configuration.
    Expected structure:
    {
        "Path": "e:\\BusinessObjects",
        "Attributes": { "ReadOnly": false, "Hidden": false, "System": false },
        "Permissions": [ { "AccountName": "Domain\\User", "Access": "FullControl" } ],
        "Share": { ... }
    }
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

Write-Verbose "Ensuring Directory: $($Config.Path)"

# 1. Ensure Directory Exists
if (-not (Test-Path -Path $Config.Path)) {
    Write-Verbose "Directory does not exist. Creating: $($Config.Path)"
    New-Item -Path $Config.Path -ItemType Directory -Force | Out-Null
} else {
    Write-Verbose "Directory already exists: $($Config.Path)"
}

# 2. Apply Attributes
if ($Config.Attributes) {
    $item = Get-Item -Path $Config.Path
    
    if ($null -ne $Config.Attributes.ReadOnly) {
        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReadOnly) -ne $Config.Attributes.ReadOnly) {
            Write-Verbose "Setting ReadOnly to $($Config.Attributes.ReadOnly)"
            if ($Config.Attributes.ReadOnly) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::ReadOnly
            } else {
                $item.Attributes = $item.Attributes -band (-not [System.IO.FileAttributes]::ReadOnly)
            }
        }
    }
    
    if ($null -ne $Config.Attributes.Hidden) {
        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -ne $Config.Attributes.Hidden) {
            Write-Verbose "Setting Hidden to $($Config.Attributes.Hidden)"
            if ($Config.Attributes.Hidden) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
            } else {
                $item.Attributes = $item.Attributes -band (-not [System.IO.FileAttributes]::Hidden)
            }
        }
    }

    if ($null -ne $Config.Attributes.System) {
        if ($item.Attributes.HasFlag([System.IO.FileAttributes]::System) -ne $Config.Attributes.System) {
             Write-Verbose "Setting System attribute to $($Config.Attributes.System)"
             if ($Config.Attributes.System) {
                $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::System
            } else {
                $item.Attributes = $item.Attributes -band (-not [System.IO.FileAttributes]::System)
            }
        }
    }
}

# 3. Apply Permissions (ACLs)
if ($Config.Permissions -or $Config.RemovePermissions) {
    $acl = Get-Acl -Path $Config.Path
    $aclChanged = $false

    if ($Config.RemovePermissions) {
        foreach ($accToRemove in $Config.RemovePermissions) {
            $rules = $acl.Access | Where-Object { 
                $_.IdentityReference.Value -eq $accToRemove -or 
                $_.IdentityReference.Value -match "\\$accToRemove`$" 
            }
            if ($rules) {
                foreach ($rule in $rules) {
                    # Needs specific cast back to FileSystemAccessRule
                    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $rule.IdentityReference,
                        $rule.FileSystemRights,
                        $rule.InheritanceFlags,
                        $rule.PropagationFlags,
                        $rule.AccessControlType
                    )
                    if ($acl.RemoveAccessRule($accessRule)) {
                        $aclChanged = $true
                    }
                }
                Write-Host "Removed explicit NTFS permissions for $accToRemove" -ForegroundColor DarkYellow
            } else {
                Write-Verbose "No explicit NTFS permissions found to remove for $accToRemove"
            }
        }
    }

    if ($Config.Permissions) {
        foreach ($perm in $Config.Permissions) {
            # Default to Allow if not specified
            $type = if ($perm.Type) { $perm.Type } else { "Allow" }
            # Default to ContainerInherit, ObjectInherit if not specified (standard for folders)
            $inheritance = if ($perm.Inheritance) { $perm.Inheritance } else { "ContainerInherit, ObjectInherit" }
            $propagation = if ($perm.Propagation) { $perm.Propagation } else { "None" }
    
            try {
                $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $perm.AccountName,
                    $perm.Access,
                    $inheritance,
                    $propagation,
                    $type
                )
                
                $acl.AddAccessRule($accessRule) 
                $aclChanged = $true
                Write-Verbose "Added/Updated permission for $($perm.AccountName)"
            }
            catch {
                Write-Warning "Failed to create access rule for $($perm.AccountName): $_"
            }
        }
    }

    if ($aclChanged) {
        Set-Acl -Path $Config.Path -AclObject $acl
    }
}

# 4. Ensure Shares
$sharesToProcess = @()
if ($Config.Share) { $sharesToProcess += $Config.Share }
if ($Config.Shares) { $sharesToProcess += $Config.Shares }

foreach ($shareConfig in $sharesToProcess) {
    if ($shareConfig.Name) {
        $shareName = $shareConfig.Name
        Write-Verbose "Ensuring Share: $shareName"
        
        if (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue) {
            # Share exists, update if needed?
            # Basic check: Ensure path matches
            $existing = Get-SmbShare -Name $shareName
            if ($existing.Path -ne $Config.Path) {
                Write-Warning "Share $shareName exists but points to different path ($($existing.Path)). Fix manually or rename."
            }
        } else {
            # Create new share
            try {
                New-SmbShare -Name $shareName -Path $Config.Path -Description $shareConfig.Description -ErrorAction Stop | Out-Null
                Write-Verbose "Created Share $shareName"
            } catch {
                Write-Error "Failed to create share $shareName : $_"
            }
        }

        # Apply Share Permissions
        if ($shareConfig.RemovePermissions) {
            foreach ($accToRemove in $shareConfig.RemovePermissions) {
                Write-Verbose "Removing explicit Share permissions for $accToRemove"
                try {
                    Revoke-SmbShareAccess -Name $shareName -AccountName $accToRemove -Force | Out-Null
                    Write-Host "Removed explicit Share Access for $accToRemove on $shareName" -ForegroundColor DarkYellow
                } catch {
                    Write-Warning "Failed to revoke share access for $($accToRemove): $_"
                }
            }
        }

        if ($shareConfig.Permissions) {
           foreach ($perm in $shareConfig.Permissions) {
               $access = $perm.Access
               
               # Handle terminology mismatch: NTFS uses "FullControl", SMB Uses "Full"
               if ($access -eq "FullControl") { $access = "Full" }

               # Grant-SmbShareAccess handles adding/updating
               try {
                   Grant-SmbShareAccess -Name $shareName -AccountName $perm.AccountName -AccessRight $access -Force | Out-Null
                   Write-Verbose "Granted Share Access: $access to $($perm.AccountName) on $shareName"
               } catch {
                   Write-Warning "Failed to grant share access for $($perm.AccountName): $_"
               }
           }
        }
    }
}
