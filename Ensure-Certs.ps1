[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [array]$Config
)

foreach ($cert in $Config) {
    if (-not $cert.SecureFile -or -not $cert.PasswordKey -or -not $cert.ManageForAccount) {
        Write-Warning "Certificate configuration is missing SecureFile, PasswordKey, or ManageForAccount. Skipping."
        continue
    }

    # Certificate drops will be placed here by the pipeline securely
    $certPath = Join-Path ".\Certificates" $cert.SecureFile
    $certPath = (Resolve-Path $certPath).Path

    # Dynamically resolve the password from the pipeline environment variables
    $certPassword = [Environment]::GetEnvironmentVariable($cert.PasswordKey)

    if (-not $certPassword) {
        Write-Warning "Failed to resolve password variable '$($cert.PasswordKey)' from environment. Skipping $($cert.SecureFile)"
        continue
    }

    if (-not (Test-Path $certPath)) {
        Write-Warning "Certificate file not found at: $certPath. Did the pipeline download it securely?"
        continue
    }

    $storeLocation = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    if ($cert.ManageForAccount -eq "User") {
        $storeLocation = [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
    }

    Write-Host "Ensuring certificate $certPath is installed to $storeLocation\My..." -ForegroundColor Cyan

    try {
        # Load the certificate into memory to compute Thumbprint and validate Password
        $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        
        $keyFlags =
            if ($storeLocation -eq [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) {
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
            }
            else {
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
            }

        $keyFlags = $keyFlags `
            -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet `
            -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable

        $certObj = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $certPath,
            $certPassword,
            $keyFlags
        )



        $thumbprint = $certObj.Thumbprint
        
        # Open the Personal store based on the requested account context
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::My, $storeLocation)
        $store.Open('ReadWrite')
        
        $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint }
        
        if (-not $existing) {
            Write-Host "  -> Installing certificate ($thumbprint)..." -ForegroundColor Yellow
            $store.Add($certObj)
            Write-Host "  -> Certificate installed successfully." -ForegroundColor Green
        } else {
            Write-Host "  -> Certificate ($thumbprint) is already installed." -ForegroundColor DarkGreen
        }

        # Handle Private Key Read Permissions
        if ($cert.ReadAccessAccounts -and $storeLocation -eq [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine) {
             # Re-fetch from the actual store so we get the persisted Private Key context, not the in-memory parsed one
             $installedCert = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint }
             if ($installedCert -and $installedCert.HasPrivateKey) {
                 Write-Verbose "Configuring Private Key permissions..."
                 $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($installedCert)
                 
                 if ($rsaKey -and $rsaKey.Key -and $rsaKey.Key.UniqueName) {
                    $keyName = $rsaKey.Key.UniqueName
                    $machineKeyPath = "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\$keyName"
                    $cngKeyPath = "$env:ProgramData\Microsoft\Crypto\Keys\$keyName" # Just in case it's CNG
                    
                    $keyPath = if (Test-Path $machineKeyPath) { $machineKeyPath } elseif (Test-Path $cngKeyPath) { $cngKeyPath } else { $null }

                    if ($keyPath) {
                        try {
                            $acl = Get-Acl -Path $keyPath
                            foreach ($account in $cert.ReadAccessAccounts) {
                                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, "Read", "Allow")
                                $acl.SetAccessRule($rule)
                                Write-Host "  -> Granted Read access to private key for: $account " -ForegroundColor Green
                            }
                            Set-Acl -Path $keyPath -AclObject $acl
                        } catch {
                            Write-Warning "Failed to set Private Key ACLs for $thumbprint on $keyPath : $_"
                        }
                    } else {
                        Write-Warning "Could not locate physical private key file for $thumbprint to set permissions."
                    }
                 } else {
                     Write-Warning "Could not extract RSA Private Key context for $thumbprint."
                 }
             }
        }

        # Assign accounts and permissions to the certificate        
        # Permission mapping
        $permissionMap = @{
            Read        = 'R'
            FullControl = 'F'
        }

        Write-Host "Resolving certificate from store: $storeLocation"

        # Get certificate from store
        $theCert = Get-Item "Cert:\$storeLocation\My\$thumbprint"
        Write-Host "Checking certificate: $($theCert.Subject)"

        # --- CNG PRIVATE KEY RESOLUTION ---
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($theCert)
        if (-not $rsa) {
            throw "Certificate has no CNG RSA private key"
        }

        $keyName = $rsa.Key.UniqueName
        if (-not $keyName) {
            throw "Unable to resolve CNG key UniqueName"
        }

        $keyPath = "C:\ProgramData\Microsoft\Crypto\Keys\$keyName"

        if (-not (Test-Path $keyPath)) {
            throw "CNG private key file not found: $keyPath"
        }

        Write-Host "Private key path: $keyPath"

        # Get current ACL once
        $acl = Get-Acl $keyPath


        foreach ($entry in $cert.Accounts.PSObject.Properties) {
            $account    = $entry.Name
            $permission = $entry.Value

            if (-not $permissionMap.ContainsKey($permission)) {
                Write-Warning "Unsupported permission '$permission' for $account - skipping"
                continue
            }

            $requiredRight = $permissionMap[$permission]

            # Get existing allow rule for this account
            $existingRule = $acl.Access | Where-Object {
                $_.IdentityReference -eq $account -and
                $_.AccessControlType -eq 'Allow'
            }

            $needsUpdate = $true

            if ($existingRule) {

                $hasFullControl =
                    ($existingRule.FileSystemRights -band
                    [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                    [System.Security.AccessControl.FileSystemRights]::FullControl

                $hasReadOnly =
                    ($existingRule.FileSystemRights -band
                    [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                    [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -and
                    -not $hasFullControl

                if ($permission -eq 'Read' -and $hasReadOnly) {
                    $needsUpdate = $false
                }
                elseif ($permission -eq 'FullControl' -and $hasFullControl) {
                    $needsUpdate = $false
                }
                else {
                    # ? Wrong permission — remove existing rule before re-grant
                    Write-Host "Replacing incorrect permission for $account"
                    icacls $keyPath /remove "$account" | Out-Null
                }
            }

            if ($needsUpdate) {
                Write-Host "Applying $permission permission for $account"
                icacls $keyPath /grant "$($account):$requiredRight" | Out-Null
            }
            else {
                Write-Host "Permission already correct for $account - skipping"
            }
        }






#         $cert = Get-Item "$storeLocation\My\$thumbprint"
# Write-Host "Checking... $cert"
#         $keyName = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
#         $keyPath = "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\$keyName"

#         $keyPath
        
#         $account = "DOMAIN\ServiceAcct"

#         icacls $keyPath /grant "$account:R"



        $store.Close()
        $certObj.Reset()
    } catch {
        Write-Error "Failed to install certificate $certPath : $($_.Exception.Message)"
    }
}

