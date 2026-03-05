<#
.SYNOPSIS
    Replaces tokens in text files with values from a provided dictionary or Environment Variables.

.DESCRIPTION
    This script provides a native PowerShell alternative to the Azure DevOps "Replace Tokens" marketplace task.
    It scans a specified file (or all files in a folder matching a filter) for a specific token pattern
    (default: #{TokenName}#) and replaces it with the corresponding value from the pipeline's environment variables.

.PARAMETER TargetPath
    The path to a specific file, or a folder to recursively scan.

.PARAMETER TokenPrefix
    The prefix string identifying a token (Default: "#{")

.PARAMETER TokenSuffix
    The suffix string identifying a token (Default: "}#")

.PARAMETER Values
    Optional. A Hashtable of explicit Keys/Values to replace. If not provided, it auto-reads from $Env: variables.

.EXAMPLE
    .\Convert-Tokens.ps1 -TargetPath ".\MachineConfiguration.json"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$TargetPath,

    [Parameter(Mandatory=$false)]
    [string]$TokenPrefix = "#{",

    [Parameter(Mandatory=$false)]
    [string]$TokenSuffix = "}#",

    [Parameter(Mandatory=$false)]
    [hashtable]$Values
)

# Expand the path
$resolvedPath = Resolve-Path $TargetPath -ErrorAction Stop
$filesToScan = @()

if ((Get-Item $resolvedPath) -is [System.IO.DirectoryInfo]) {
    $filesToScan = Get-ChildItem -Path $resolvedPath -File -Recurse
} else {
    $filesToScan = @(Get-Item $resolvedPath)
}

# Escape prefixes for Regex
$rgxPrefix = [regex]::Escape($TokenPrefix)
$rgxSuffix = [regex]::Escape($TokenSuffix)
$pattern = "$rgxPrefix(.*?)$rgxSuffix"

Write-Verbose "Scanning $($filesToScan.Count) files for token pattern: $pattern"

foreach ($file in $filesToScan) {
    $content = Get-Content $file.FullName -Raw
    $tokenMatches = [regex]::Matches($content, $pattern)
    
    if ($tokenMatches.Count -gt 0) {
        Write-Host "Found $($tokenMatches.Count) tokens in $($file.Name)" -ForegroundColor Cyan
        
        $replacedCount = 0
        foreach ($match in $tokenMatches) {
            $tokenName = $match.Groups[1].Value.Trim()
            $replacementValue = $null

            # 1. Check explicit Hashtable first
            if ($Values -and $Values.ContainsKey($tokenName)) {
                $replacementValue = $Values[$tokenName]
            }
            # 2. Fallback to Environment Variables
            else {
                $envValue = [Environment]::GetEnvironmentVariable($tokenName)
                if ($null -ne $envValue) {
                    $replacementValue = $envValue
                }
            }

            if ($null -ne $replacementValue) {
                # Perform the replacement
                $content = $content.Replace($match.Value, $replacementValue)
                Write-Host "  -> Replaced: $tokenName" -ForegroundColor Green
                $replacedCount++
            } else {
                Write-Warning "  -> Missing Value for Token: $tokenName ! (Left unresolved)"
            }
        }

        if ($replacedCount -gt 0) {
            # Save the file back with UTF8 encoding
            $content | Set-Content $file.FullName -Encoding UTF8
            Write-Host "Saved changes to $($file.Name)" -ForegroundColor DarkGreen
        }
    }
}
