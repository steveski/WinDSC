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
if ($Config.Permissions) {
    $acl = Get-Acl -Path $Config.Path
    $aclChanged = $false

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
            
            # Check if this rule is already present efficiently is hard, so we assume 'SetAccessRule' 
            # which adds or modifies. To be purely idempotent we would check specific rules.
            # Here we just AddAccessRule. To reset/ensure EXACTLY, we might need Purge, but 
            # "Ensure" usually implies "Make sure this exists", not "Remove everything else".
            # Users request: "If something needs to be changed... ensure data like contents... are not destroyed."
            # So generic "Add/Update" is safer than "Replace All".
            
            $acl.AddAccessRule($accessRule) 
            $aclChanged = $true
            Write-Verbose "Added/Updated permission for $($perm.AccountName)"
        }
        catch {
            Write-Warning "Failed to create access rule for $($perm.AccountName): $_"
        }
    }

    if ($aclChanged) {
        Set-Acl -Path $Config.Path -AclObject $acl
    }
}

# 4. Ensure Share
if ($Config.Share) {
    if ($Config.Share.Name) {
        $shareName = $Config.Share.Name
        Write-Verbose "Ensuring Share: $shareName"
        
        if (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue) {
            # Share exists, update if needed?
            # Basic check: Ensure path matches
            $existing = Get-SmbShare -Name $shareName
            if ($existing.Path -ne $Config.Path) {
                Write-Warning "Share $shareName exists but points to different path ($($existing.Path)). Fix manually or rename."
            }
            # Could update Description, etc. using Set-SmbShare
        } else {
            # Create new share
            try {
                New-SmbShare -Name $shareName -Path $Config.Path -Description $Config.Share.Description -ErrorAction Stop | Out-Null
                Write-Verbose "Created Share $shareName"
            } catch {
                Write-Error "Failed to create share $shareName : $_"
            }
        }

        # Apply Share Permissions
        if ($Config.Share.Permissions) {
           foreach ($perm in $Config.Share.Permissions) {
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
