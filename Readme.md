# Windows & IIS Configuration as Code (DSC)

A modular, highly generic, JSON-driven PowerShell Configuration-as-Code suite for managing Windows Server infrastructure and deep IIS web server properties dynamically. 

This repository allows you to define complex Server Features, Directories, Networking (Hosts), Event Logs, Application Pools, Websites, and Nested Web Applications entirely through a single JSON configuration file. It implements idempotency, automatically preventing configuration drift and safely executing across clustered Node environments based on targeting logic.

## Overview

The engine relies on a main orchestrator script `Apply-IISConfiguration.ps1` that ingests `MachineConfiguration.json` and evaluates if the current server's hostname matches the target array. If it matches, it delegates provisioning actions down to specialized execution scripts:
- `Ensure-Server-Features.ps1`: Syncs Windows Features/Roles.
- `Ensure-Directory.ps1`: Ensures physical directories exist, apply NTFS ACLs, and configures concurrent SMB Shares.
- `Ensure-AppPool.ps1`: Provisions IIS application pools with support for dynamic schema routing.
- `Ensure-Website.ps1`: Provisions Websites, bindings, trace logging, nested WebApps, and applies advanced IIS configurations including Authentication routing.
- `Ensure-Hosts.ps1`: Syncs custom DNS mappings in the Windows `hosts` file.
- `Ensure-EventLog.ps1`: Creates custom Application Windows Event Sources.

## Features

- **Generic Schema-Agnostic IIS Property Engine**: Unlike standard IIS management scripts, you are not strictly limited to top-level configured properties. Any key passed in an `AdvancedSettings` dictionary will be automatically passed down to the COM Object.
  - It automatically formats JSON arrays into PowerShell hashtables required for IIS collection lists (like scheduled recycling times).
  - It automatically maps `PascalCase` bindings in the JSON to the strict `camelCase` schema IIS expects.
  - It detects explicit root schema XPath overrides (e.g., `system.webServer/security/authentication/...`) via forward slashes and routes them away from standard Site configuration logic down into `Set-WebConfigurationProperty` dynamically.

---

## Example Usage

Execute the generic orchestrator locally:
```powershell
# Open an Elevated (Administrator) PowerShell prompt
.\Apply-IISConfiguration.ps1
```

Or pass a specific JSON environment file:
```powershell
.\Apply-IISConfiguration.ps1 -ConfigurationPath ".\Config\ProductionExtranet.json"
```

---

## Configuration File Schema Specification

The `MachineConfiguration.json` is fundamentally a JSON Array containing configuration objects. The script will iterate through the array until it finds an object where the executing server's hostname exists inside `TargetMachineNames`.

*Below is a comprehensive schema definition of all configurable elements available inside a configuration object.*

### `TargetMachineNames` (Array of Strings)
List of hostnames where this configuration block should apply.
- e.g., `["Server01Prod", "Server02Prod"]`

### `TimeZone` (String)
Sets the Windows OS Time Zone.
- Must be a valid Windows Time Zone ID (e.g., `"AUS Eastern Standard Time"`, `"Pacific Standard Time"`).

### `EnabledFeatures` / `DisabledFeatures` (Array of Strings)
Manages ServerManager Windows Features/Roles actively.
- Valid values are canonical Windows Feature names (e.g., `"Web-Static-Content"`, `"DHCP"`, `"Web-WebServer"`).

### `Hosts` (Object)
Key-Value pairs defining local DNS overrides appended to `%windir%\system32\drivers\etc\hosts`.
- Keys: The Hostname (e.g., `"extranet.local.tv"`)
- Values: The IPv4 Address (e.g., `"127.0.0.1"`)

### `HostsToRemove` (Array of Strings)
List of stale hostnames to actively rip out of the system `hosts` file.
- e.g., `["old.extranet.com"]`

### `EventLogs` (Object)
Creates custom Windows Event Log Sources primarily used by application backends.
- Key: Custom Source Name (e.g., `"MyCustomAppSource"`)
- Value (Object):
  - `"LogName"` (String) - Defaults to `"Application"` if omitted. The Event Log category.
  - *Note: `EventId` and `Level` are reserved for test-payload logging but primarily reserved.*

### `Directories` (Array of Objects)
Manages standard FileSystem folders, attributes, explicit NTFS Security ACLs, and SMB File Sharing configurations.
- `"Path"` (String) - Local physical path (e.g., `"c:\\BusinessObjects"`). Will be created if it does not exist.
- `"Attributes"` (Object):
  - `"ReadOnly"` (Bool)
  - `"Hidden"` (Bool)
  - `"System"` (Bool)
- `"Permissions"` (Array of Objects) - **NTFS Local File System Security:**
  - `"AccountName"` (String) - Example: `"Administrators"`, `"Domain\User"`, `"IUSR"`.
    - `"Access"` (String) - A standard FileSystemRights Enum. Valid Options:
    - `"FullControl"`
    - `"Modify"`
    - `"ReadAndExecute"`
    - `"ListDirectory"`
    - `"Read"`
    - `"Write"`
- `"RemovePermissions"` (Array of Strings) - Stale identities to actively revoke. E.g., `["Domain\\OldUser"]`
- `"Shares"` (Array of Objects) - **SMB File Sharing:**
  - Multiple shares can be hosted over the same directory.
  - `"Name"` (String) - The exposed network share name.
  - `"Description"` (String)
  - `"Type"` (String) - Usually `"Folder"`.
  - `"AdministrativeShare"` (Bool)
  - `"Permissions"` (Array of Objects) - **SMB Share Level Security:**
    - `"AccountName"` (String) - Identity definition.
    - `"Access"` (String) - SMB AccessRight Enum. Valid Options:
      - `"Full"` (or `"FullControl"` - automatically maps down to Full)
      - `"Change"` (Read/Write without ownership)
      - `"Read"` (Read-Only)
      - `"Custom"`
  - `"RemovePermissions"` (Array of Strings) - Stale identities to actively revoke. E.g., `["Domain\\OldUser"]`

### `IISAppPools` (Array of Objects)
Dynamically manages discrete AppPools.
- `"Name"` (String) - Application pool name.
- `"ManagedRuntimeVersion"` (String) - Options: `"v4.0"`, `"v2.0"`, `""` (for No Managed Code).
- `"ManagedPipelineMode"` (String) - Options: `"Integrated"`, `"Classic"`.
- `"AdvancedSettings"` (Object/Dictionary) - Dynamic generic property ingestion. Example keys:
  - `"StartMode": "AlwaysRunning"`
  - `"ProcessModel.idleTimeout": "00:00:00"`
  - IIS Collections can be defined explicitly as JSON arrays natively:
    ```json
    "recycling.periodicRestart.schedule": [
        { "value": "02:00:00" },
        { "value": "15:00:00" }
    ]
    ```

### `IISWebSites` (Array of Objects)
Manages Server Websites, their physical boundaries, traffic bindings, trace-logging, and nested application tiers.
- `"SiteName"` (String) - Display name in IIS.
- `"ContentPath"` (String) - Physical host directory mapping.
- `"AppPool"` (String) - Name of an existing or requested AppPool.
- `"FailedRequestTracing"` (Object)
  - `"Enabled"` (Bool)
  - `"LogDirectory"` (String) - Disk location for the trace XMLs.
  - `"MaxTraceFiles"` (Integer) - Maximum rolling trace caps.
- `"Bindings"` (Array of Objects)
  - `"Protocol"` (String) - Options: `"http"`, `"https"`, `"ftp"`.
  - `"Port"` (Integer) - Traffic port limitation length.
  - `"HostHeader"` (String) - DNS Binding request requirement.
- `"AdvancedSettings"` (Object/Dictionary) - Dynamic Website property integration.
  - Implicit schema redirection automatically maps certain website constants down:
    - `"PhysicalPathCredential"` -> Resolves to `"virtualDirectoryDefaults.physicalPathCredential"`
    - `"PreloadEnabled"` -> Resolves to `"applicationDefaults.preloadEnabled"`
  - Explicit overriding natively unlocks deep WebConfiguration paths dynamically. E.g. Disabling Windows IIS authentication but keeping Anonymous authentication active against the pool identity:
    ```json
    "system.webServer/security/authentication/anonymousAuthentication.enabled": true,
    "system.webServer/security/authentication/anonymousAuthentication.userName": "",
    "system.webServer/security/authentication/windowsAuthentication.enabled": false
    ```
- `"WebApps"` (Array of Objects) - Nested IIS Applications provisioned underneath the parent hierarchy.
  - Takes identical generic configurations to Websites (e.g. `"Name"`, `"ContentPath"`, `"AppPool"`, `"Bindings"`, `"AdvancedSettings"` arrays are natively evaluated and mapped down dynamically to `"SiteName/WebAppName"` paths).
