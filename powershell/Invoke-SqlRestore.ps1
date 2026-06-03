<#
.SYNOPSIS
    RaaS Framework - SQL Server Restore Orchestrator
.DESCRIPTION
    Main restore workflow script. Orchestrates full, differential, and log
    restores with pre/post validation, structured JSON logging, and dry-run support.
.PARAMETER SourceServer
    Source SQL Server instance (hostname\instance).
.PARAMETER TargetServer
    Target SQL Server instance (hostname\instance).
.PARAMETER DatabaseName
    Name of the database to restore.
.PARAMETER RestoreType
    Restore type: Full | Differential | Log
.PARAMETER BackupPath
    Optional override for the backup file path. If omitted, the script
    auto-discovers the latest backup from the backup share.
.PARAMETER BackupShare
    UNC path to the backup share root. Default: \\backup-server\SQLBackups
.PARAMETER OverwriteExisting
    If specified, existing database on target will be overwritten.
.PARAMETER DryRun
    Simulate all steps without making changes. Useful for validation.
.PARAMETER JobId
    RaaS job identifier for structured log correlation.
.PARAMETER InventoryServer
    Inventory/CMDB SQL Server for logging audit records.
.EXAMPLE
    .\Invoke-SqlRestore.ps1 -SourceServer "SQL-PROD-01" -TargetServer "SQL-UAT-01" `
        -DatabaseName "OrdersDB" -RestoreType Full -OverwriteExisting -JobId "JOB-ABC123"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceServer,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetServer,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[A-Za-z0-9_\-]{1,128}$')]
    [string]$DatabaseName,

    [Parameter()]
    [ValidateSet('Full', 'Differential', 'Log')]
    [string]$RestoreType = 'Full',

    [Parameter()]
    [string]$BackupPath = '',

    [Parameter()]
    [string]$BackupShare = '\\backup-server\SQLBackups',

    [Parameter()]
    [switch]$OverwriteExisting,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$JobId = [System.Guid]::NewGuid().ToString().Substring(0, 8).ToUpper(),

    [Parameter()]
    [string]$InventoryServer = 'SQL-INVENTORY-01',

    [Parameter()]
    [int]$CommandTimeoutSeconds = 3600,

    [Parameter()]
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Structured Logger ────────────────────────────────────────────────────────

$script:LogBuffer = [System.Collections.Generic.List[hashtable]]::new()

function Write-RaaSLog {
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO',
        [string]$Message,
        [string]$Source = 'PowerShell'
    )
    $entry = @{
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
        level     = $Level
        message   = $Message
        source    = $Source
        job_id    = $JobId
    }
    $script:LogBuffer.Add($entry)

    $color = switch ($Level) {
        'INFO'  { 'Cyan'   }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        'DEBUG' { 'Gray'   }
    }
    $ts = $entry.timestamp
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color

    if ($LogPath -ne '') {
        "[$ts] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
}

function Write-RaaSResult {
    param([hashtable]$Result)
    $Result | ConvertTo-Json -Depth 10 | Write-Output
}

# ─── Helper: Build Connection String ─────────────────────────────────────────

function Get-SqlConnectionString {
    param([string]$ServerInstance, [string]$Database = 'master')
    return "Server=$ServerInstance;Database=$Database;Integrated Security=True;Connect Timeout=30;Application Name=RaaS-Framework;"
}

# ─── Helper: Invoke SQL Query ─────────────────────────────────────────────────

function Invoke-RaaSQuery {
    param(
        [string]$ServerInstance,
        [string]$Query,
        [string]$Database = 'master',
        [int]$Timeout = 300
    )
    if ($DryRun) {
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Would execute SQL on $ServerInstance : $($Query.Substring(0, [Math]::Min(80, $Query.Length)))..."
        return $null
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = Get-SqlConnectionString -ServerInstance $ServerInstance -Database $Database
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $Query
        $cmd.CommandTimeout = $Timeout
        $reader = $cmd.ExecuteReader()
        $dt = New-Object System.Data.DataTable
        $dt.Load($reader)
        return $dt
    }
    finally {
        $conn.Close()
    }
}

# ─── Step 1: Validate Input Parameters ───────────────────────────────────────

function Invoke-PreFlightChecks {
    Write-RaaSLog -Message "Starting pre-flight checks..."

    # Confirm source and target are reachable
    foreach ($srv in @($SourceServer, $TargetServer)) {
        Write-RaaSLog -Message "Testing connectivity to $srv..."
        if (-not $DryRun) {
            $ping = Test-NetConnection -ComputerName ($srv.Split('\')[0]) -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue
            if (-not $ping) {
                throw "Cannot reach SQL Server '$srv' on port 1433. Check firewall and service status."
            }
        }
        else {
            Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Skipping network connectivity test for $srv."
        }
        Write-RaaSLog -Message "Connectivity OK: $srv"
    }

    # Check that target server is not a production server (safety guard)
    if ($TargetServer -match '-PROD-' -or $TargetServer -match 'PROD\d') {
        Write-RaaSLog -Level 'WARN' -Message "Target server '$TargetServer' appears to be a PRODUCTION instance. Elevated governance required."
    }

    Write-RaaSLog -Message "Pre-flight checks completed."
}

# ─── Step 2: Discover Backup Chain ───────────────────────────────────────────

function Get-LatestBackupPath {
    Write-RaaSLog -Message "Discovering latest $RestoreType backup for $DatabaseName on $SourceServer..."

    if ($BackupPath -ne '') {
        if (-not $DryRun -and -not (Test-Path $BackupPath)) {
            throw "Specified backup file not found: $BackupPath"
        }
        Write-RaaSLog -Message "Using specified backup path: $BackupPath"
        return $BackupPath
    }

    # Query msdb for latest backup
    $query = switch ($RestoreType) {
        'Full' {
            @"
SELECT TOP 1
    bs.backup_finish_date,
    bs.backup_size / 1073741824.0 AS size_gb,
    bmf.physical_device_name AS backup_path
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = '$DatabaseName'
  AND bs.type = 'D'
  AND bs.is_copy_only = 0
ORDER BY bs.backup_finish_date DESC
"@
        }
        'Differential' {
            @"
SELECT TOP 1
    bs.backup_finish_date,
    bs.backup_size / 1073741824.0 AS size_gb,
    bmf.physical_device_name AS backup_path
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = '$DatabaseName'
  AND bs.type = 'I'
ORDER BY bs.backup_finish_date DESC
"@
        }
        'Log' {
            @"
SELECT TOP 1
    bs.backup_finish_date,
    bs.backup_size / 1073741824.0 AS size_gb,
    bmf.physical_device_name AS backup_path
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = '$DatabaseName'
  AND bs.type = 'L'
ORDER BY bs.backup_finish_date DESC
"@
        }
    }

    $result = Invoke-RaaSQuery -ServerInstance $SourceServer -Query $query
    if ($DryRun) {
        $simulatedPath = "$BackupShare\$SourceServer\$DatabaseName\${DatabaseName}_FULL_$(Get-Date -Format 'yyyyMMdd').bak"
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Simulated backup path: $simulatedPath"
        return $simulatedPath
    }

    if (-not $result -or $result.Rows.Count -eq 0) {
        throw "No $RestoreType backup found for database '$DatabaseName' on server '$SourceServer'."
    }

    $row      = $result.Rows[0]
    $bkPath   = $row.backup_path
    $bkDate   = $row.backup_finish_date
    $bkSizeGb = [Math]::Round($row.size_gb, 2)

    Write-RaaSLog -Message "Backup found: $bkPath | Date: $bkDate | Size: ${bkSizeGb} GB"
    return $bkPath
}

# ─── Step 3: Check Target Disk Space ─────────────────────────────────────────

function Test-TargetDiskSpace {
    param([string]$ResolvedBackupPath)
    Write-RaaSLog -Message "Checking disk space on target server $TargetServer..."

    if ($DryRun) {
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Skipping disk space check."
        return
    }

    # Estimate required space: backup size * 1.5 (for data file expansion)
    $backupSizeBytes = (Get-Item $ResolvedBackupPath -ErrorAction SilentlyContinue)?.Length
    $requiredGb      = if ($backupSizeBytes) { [Math]::Round($backupSizeBytes / 1GB * 1.5, 2) } else { 10.0 }

    # Check via WMI on target
    $targetHost = $TargetServer.Split('\')[0]
    $disk = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $targetHost `
        -Filter "DriveType=3" -ErrorAction SilentlyContinue |
        Sort-Object FreeSpace -Descending | Select-Object -First 1

    if ($disk) {
        $freeGb = [Math]::Round($disk.FreeSpace / 1GB, 2)
        Write-RaaSLog -Message "Target disk free space: ${freeGb} GB on drive $($disk.DeviceID)"
        if ($freeGb -lt $requiredGb) {
            throw "Insufficient disk space on target. Required: $requiredGb GB, Available: $freeGb GB."
        }
        Write-RaaSLog -Message "Disk space check passed (${freeGb} GB free, ${requiredGb} GB required)."
    }
    else {
        Write-RaaSLog -Level 'WARN' -Message "Could not query disk space on $targetHost via WMI. Proceeding cautiously."
    }
}

# ─── Step 4: Execute Restore ─────────────────────────────────────────────────

function Invoke-DatabaseRestore {
    param([string]$ResolvedBackupPath)

    $withClause = @()
    if ($OverwriteExisting) { $withClause += 'REPLACE' }
    $withClause += 'STATS = 10'
    $withClause += 'NORECOVERY'   # Leave in restoring state for diff/log chain

    # For the final restore in the chain, use RECOVERY
    if ($RestoreType -eq 'Full') {
        $withClause = $withClause | Where-Object { $_ -ne 'NORECOVERY' }
        $withClause += 'RECOVERY'
    }

    $withStr = $withClause -join ', '

    $restoreCmd = switch ($RestoreType) {
        'Full'         { "RESTORE DATABASE [$DatabaseName] FROM DISK = N'$ResolvedBackupPath' WITH $withStr;" }
        'Differential' { "RESTORE DATABASE [$DatabaseName] FROM DISK = N'$ResolvedBackupPath' WITH DIFFERENTIAL, $withStr;" }
        'Log'          { "RESTORE LOG [$DatabaseName] FROM DISK = N'$ResolvedBackupPath' WITH $withStr;" }
    }

    Write-RaaSLog -Message "Executing: $($restoreCmd.Substring(0, [Math]::Min(120, $restoreCmd.Length)))..."

    if ($DryRun) {
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Would execute restore command on $TargetServer."
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Full T-SQL: $restoreCmd"
        return
    }

    # Execute restore with progress tracking via SqlClient events
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = Get-SqlConnectionString -ServerInstance $TargetServer
    $conn.FireInfoMessageEventOnUserErrors = $true

    Register-ObjectEvent -InputObject $conn -EventName 'InfoMessage' -Action {
        $msg = $Event.SourceEventArgs.Message
        if ($msg -match 'percent') {
            Write-RaaSLog -Message "RESTORE progress: $msg" -Source 'SqlClient'
        }
    } | Out-Null

    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $restoreCmd
        $cmd.CommandTimeout = $CommandTimeoutSeconds
        $cmd.ExecuteNonQuery() | Out-Null
        Write-RaaSLog -Message "Restore command completed on $TargetServer."
    }
    finally {
        $conn.Close()
    }
}

# ─── Step 5: Post-Restore Validation ─────────────────────────────────────────

function Invoke-PostRestoreValidation {
    Write-RaaSLog -Message "Running post-restore validation: DBCC CHECKDB on [$DatabaseName]..."

    $checkCmd = "DBCC CHECKDB ([$DatabaseName]) WITH NO_INFOMSGS, ALL_ERRORMSGS;"

    if ($DryRun) {
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Would run DBCC CHECKDB."
        return @{ passed = $true; errors = 0 }
    }

    try {
        Invoke-RaaSQuery -ServerInstance $TargetServer -Query $checkCmd -Database $DatabaseName -Timeout 1800
        Write-RaaSLog -Message "DBCC CHECKDB passed — database integrity confirmed."
        return @{ passed = $true; errors = 0 }
    }
    catch {
        Write-RaaSLog -Level 'WARN' -Message "DBCC CHECKDB reported issues: $_"
        return @{ passed = $false; errors = 1; detail = $_.ToString() }
    }
}

# ─── Step 6: Register Completion in Inventory ────────────────────────────────

function Register-RestoreCompletion {
    param([string]$Status, [int]$DurationSeconds, [string]$ValidationResult)

    if ($DryRun) {
        Write-RaaSLog -Level 'DEBUG' -Message "[DryRun] Would call sp_RegisterRestoreRequest on $InventoryServer."
        return
    }

    $query = @"
EXEC dbo.sp_RegisterRestoreRequest
    @JobId            = '$JobId',
    @SourceServer     = '$SourceServer',
    @TargetServer     = '$TargetServer',
    @DatabaseName     = '$DatabaseName',
    @RestoreType      = '$RestoreType',
    @Status           = '$Status',
    @DurationSeconds  = $DurationSeconds,
    @ValidationResult = '$ValidationResult',
    @ExecutedBy       = 'RaaS-PowerShell-Agent',
    @CompletedAt      = GETUTCDATE();
"@
    try {
        Invoke-RaaSQuery -ServerInstance $InventoryServer -Query $query -Database 'RaaSInventory'
        Write-RaaSLog -Message "Restore completion registered in inventory (Job: $JobId)."
    }
    catch {
        Write-RaaSLog -Level 'WARN' -Message "Could not register completion in inventory: $_"
    }
}

# ─── Main Execution ───────────────────────────────────────────────────────────

$startTime = Get-Date
$result    = @{
    job_id            = $JobId
    source_server     = $SourceServer
    target_server     = $TargetServer
    database_name     = $DatabaseName
    restore_type      = $RestoreType
    dry_run           = $DryRun.IsPresent
    status            = 'Unknown'
    started_at        = $startTime.ToString('o')
    completed_at      = $null
    duration_seconds  = 0
    backup_path_used  = ''
    validation_result = @{}
    logs              = @()
    error             = $null
}

try {
    Write-RaaSLog -Message "══════════════════════════════════════════════════"
    Write-RaaSLog -Message " RaaS Framework — Invoke-SqlRestore.ps1"
    Write-RaaSLog -Message " Job ID      : $JobId"
    Write-RaaSLog -Message " Source      : $SourceServer"
    Write-RaaSLog -Message " Target      : $TargetServer"
    Write-RaaSLog -Message " Database    : $DatabaseName"
    Write-RaaSLog -Message " Type        : $RestoreType"
    Write-RaaSLog -Message " Overwrite   : $($OverwriteExisting.IsPresent)"
    Write-RaaSLog -Message " Dry Run     : $($DryRun.IsPresent)"
    Write-RaaSLog -Message "══════════════════════════════════════════════════"

    Invoke-PreFlightChecks

    $resolvedBackupPath = Get-LatestBackupPath
    $result.backup_path_used = $resolvedBackupPath

    Test-TargetDiskSpace -ResolvedBackupPath $resolvedBackupPath

    Invoke-DatabaseRestore -ResolvedBackupPath $resolvedBackupPath

    $validation = Invoke-PostRestoreValidation
    $result.validation_result = $validation

    $endTime                 = Get-Date
    $result.status           = 'Completed'
    $result.completed_at     = $endTime.ToString('o')
    $result.duration_seconds = [int]($endTime - $startTime).TotalSeconds

    Register-RestoreCompletion -Status 'Completed' -DurationSeconds $result.duration_seconds `
        -ValidationResult ($validation.passed ? 'PASSED' : 'WARNINGS')

    Write-RaaSLog -Message "Restore COMPLETED successfully. Duration: $($result.duration_seconds)s."
}
catch {
    $endTime                 = Get-Date
    $result.status           = 'Failed'
    $result.completed_at     = $endTime.ToString('o')
    $result.duration_seconds = [int]($endTime - $startTime).TotalSeconds
    $result.error            = $_.Exception.Message

    Write-RaaSLog -Level 'ERROR' -Message "Restore FAILED: $($_.Exception.Message)"
    Write-RaaSLog -Level 'ERROR' -Message $_.ScriptStackTrace

    Register-RestoreCompletion -Status 'Failed' -DurationSeconds $result.duration_seconds `
        -ValidationResult 'FAILED'
}
finally {
    $result.logs = $script:LogBuffer
    Write-RaaSResult -Result $result
}
