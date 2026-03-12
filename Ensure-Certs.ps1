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
        $certObj.Import($certPath, $certPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        
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

        $store.Close()
        $certObj.Reset()
    } catch {
        Write-Error "Failed to install certificate $certPath : $($_.Exception.Message)"
    }
}
