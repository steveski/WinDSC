<#
.SYNOPSIS
    Ensures specific Event Log Sources and Logs exist in Windows.

.DESCRIPTION
    Reads an EventLogs dictionary/object from the configuration. 
    Keys are the SourceNames. Values are hashtables defining the LogName and other potential properties.
    If the SourceName does not exist, it will be created.

.PARAMETER Config
    A hashtable or custom object containing 'EventLogs'.
    Expected structure:
    {
        "MyCustomAppSource": {
            "LogName": "Application"
        },
        "AnotherSource": {
            "LogName": "MyCustomLog"
        }
    }
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [object]$Config
)

# Ensure the config we received handles PowerShell's PSCustomObject gracefully
$eventLogsObject = $Config

# Iterate through the properties of the object (Keys are SourceNames, Values are properties)
foreach ($property in $eventLogsObject.PSObject.Properties) {
    if ([string]::IsNullOrWhiteSpace($property.Name)) { continue }

    $sourceName = $property.Name
    $logProps = $property.Value
    
    # Extract properties safely handles PSCustomObject or Hashtable
    $logName = if ($logProps -is [System.Management.Automation.PSCustomObject]) { $logProps.LogName } else { $logProps["LogName"] }
    
    # Default to Application log if not specified
    if (-not $logName) {
        $logName = "Application"
    }

    Write-Verbose "Ensuring Event Log Source: '$sourceName' in Log: '$logName'"

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
            Write-Verbose "Creating Event Source '$sourceName' for Log '$logName'."
            New-EventLog -LogName $logName -Source $sourceName -ErrorAction Stop
        } else {
            # Check if existing source is associated with the correct log
            $existingLog = [System.Diagnostics.EventLog]::LogNameFromSourceName($sourceName, ".")
            if ($existingLog -ne $logName) {
                Write-Warning "Source '$sourceName' exists but is associated with log '$existingLog', not the requested '$logName'. To change this, you typically need to delete the source first, which this script won't do automatically."
            } else {
                Write-Verbose "Event Source '$sourceName' already exists and is associated with Log '$logName'."
            }
        }
    } catch {
        Write-Error "Failed to ensure Event Log source '$sourceName'. Ensure the script is running as Administrator. Error: $_"
    }

    # The user request mentioned EventId and Level, which implies they want to *write* an event,
    # but the task of a DSC configuration is usually to *create* the structure (the log/source).
    # Writing actual events like a test message can be problematic if run repeatedly, but if the user wants it to log a config message:
    
    $eventId = if ($logProps -is [System.Management.Automation.PSCustomObject]) { $logProps.EventId } else { $logProps["EventId"] }
    $level = if ($logProps -is [System.Management.Automation.PSCustomObject]) { $logProps.Level } else { $logProps["Level"] }

    # If they supplied them, maybe they want a test event written when it's configured? Let's optionally do that.
    # We won't throw an error if this part fails as it's secondary.
    if ($eventId -and $level) {
        $entryType = "Information"
        if ($level -match "Warn") { $entryType = "Warning" }
        elseif ($level -match "Err") { $entryType = "Error" }

        try {
            # Write-EventLog -LogName $logName -Source $sourceName -EventId $eventId -EntryType $entryType -Message "Configuration Applied via IISDSC" -ErrorAction SilentlyContinue
            Write-Verbose "Configuration defines EventId $eventId and Level $level. Not writing test event to avoid log spam, but source is ready to receive them."
        } catch { }
    }
}
