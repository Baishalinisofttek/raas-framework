<#
.SYNOPSIS
    RaaS Framework - SQL Server Health Status Collector
.DESCRIPTION
    Queries one or more SQL Server instances for health metrics including
    CPU, memory, disk, backup status, and blocking sessions.
    Returns a structured JSON response for agent consumption.
.PARAMETER ServerList
    Comma-separated list of server instances to query.
    Example: "SQL-PROD-01,SQL-STG-01\SQLEXPRESS"
.PARAMETER InventoryServer
    Optional: query the RaaS inventory server to get the server list dynamically.
.PARAMETER TimeoutSeconds
    Per-server connection timeout in seconds.
.PARAMETER DryRun
    Return simulated data without connecting to servers.
.EXAMPLE
    .\Get-ServerStatus.ps1 -ServerList "SQL-PROD-01,SQL-STG-01"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ServerList = '',

    [Parameter()]
    [string]$InventoryServer = 'SQL-INVENTORY-01',

    [Parameter()]
    [int]$TimeoutSeconds = 15,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # Don't abort on one server failure

# ─── Logger ───────────────────────────────────────────────────────────────────

function Write-StatusLog {
    param([string]$Level = 'INFO', [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor (
        switch ($Level) { 'INFO' { 'Cyan' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    )
}

# ─── SQL Query Helper ─────────────────────────────────────────────────────────

function Invoke-ServerQuery {
    param([string]$Instance, [string]$Query, [string]$Database = 'master')
    $connStr = "Server=$Instance;Database=$Database;Integrated Security=True;Connect Timeout=$TimeoutSeconds;Application Name=RaaS-StatusCheck;"
    $conn    = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $conn.Open()
        $cmd            = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        $reader = $cmd.ExecuteReader()
        $dt = New-Object System.Data.DataTable
        $dt.Load($reader)
        return $dt
    }
    finally {
        $conn.Close()
    }
}

# ─── Collect Metrics for One Server ──────────────────────────────────────────

function Get-SingleServerStatus {
    param([string]$Instance)

    $hostname = $Instance.Split('\')[0]
    Write-StatusLog -Message "Collecting status for: $Instance"

    $status = @{
        server_name      = $Instance
        checked_at       = (Get-Date -Format 'o')
        reachable        = $false
        version          = $null
        edition          = $null
        uptime_hours     = $null
        cpu_percent      = $null
        memory_used_pct  = $null
        disk_drives      = @()
        databases        = @()
        blocking_count   = 0
        open_connections = 0
        last_backup      = @{}
        backup_age_hours = $null
        health           = 'Unknown'
        alerts           = @()
        error            = $null
    }

    if ($DryRun) {
        # Return synthetic data
        $status.reachable        = $true
        $status.version          = 'SQL Server 2022 (RTM-CU12)'
        $status.edition          = 'Enterprise Edition (64-bit)'
        $status.uptime_hours     = [Math]::Round((Get-Random -Min 24 -Max 8760), 0)
        $status.cpu_percent      = [Math]::Round((Get-Random -Min 5 -Max 90), 1)
        $status.memory_used_pct  = [Math]::Round((Get-Random -Min 30 -Max 95), 1)
        $status.open_connections = Get-Random -Min 10 -Max 250
        $status.blocking_count   = Get-Random -Min 0 -Max 5
        $status.disk_drives      = @(
            @{ drive = 'C:'; total_gb = 100; free_gb = [Math]::Round((Get-Random -Min 10 -Max 80), 1); used_pct = 0 }
            @{ drive = 'E:'; total_gb = 2000; free_gb = [Math]::Round((Get-Random -Min 50 -Max 1500), 1); used_pct = 0 }
        )
        foreach ($d in $status.disk_drives) {
            $d.used_pct = [Math]::Round(100 - ($d.free_gb / $d.total_gb * 100), 1)
        }
        $status.last_backup      = @{ full = (Get-Date).AddHours(-2).ToString('o'); differential = (Get-Date).AddHours(-6).ToString('o') }
        $status.backup_age_hours = 2
        $status.health           = 'Healthy'
        return $status
    }

    try {
        # ── Version & Uptime ───────────────────────────────────────────────
        $versionDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT
    SERVERPROPERTY('ProductVersion')               AS product_version,
    SERVERPROPERTY('Edition')                      AS edition,
    sqlserver_start_time                           AS start_time,
    DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS uptime_hours
FROM sys.dm_os_sys_info;
"@
        $status.reachable    = $true
        $status.version      = $versionDt.Rows[0].product_version
        $status.edition      = $versionDt.Rows[0].edition
        $status.uptime_hours = $versionDt.Rows[0].uptime_hours

        # ── CPU ────────────────────────────────────────────────────────────
        $cpuDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT TOP 1 SQLProcessUtilization AS sql_cpu_pct
FROM (
    SELECT record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
           GETDATE() AS EventTime
    FROM (
        SELECT TOP 30 CONVERT(XML, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE '%<SystemHealth>%'
        ORDER BY timestamp DESC
    ) AS ring_data
) AS cpu_data
ORDER BY EventTime DESC;
"@
        $status.cpu_percent = if ($cpuDt.Rows.Count -gt 0) { $cpuDt.Rows[0].sql_cpu_pct } else { 0 }

        # ── Memory ─────────────────────────────────────────────────────────
        $memDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT
    physical_memory_in_use_kb / 1024.0            AS memory_used_mb,
    (SELECT value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)') AS max_memory_mb
FROM sys.dm_os_process_memory;
"@
        if ($memDt.Rows.Count -gt 0) {
            $used = [double]$memDt.Rows[0].memory_used_mb
            $max  = [double]$memDt.Rows[0].max_memory_mb
            $status.memory_used_pct = if ($max -gt 0) { [Math]::Round($used / $max * 100, 1) } else { 0 }
        }

        # ── Disk Drives ────────────────────────────────────────────────────
        $diskDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT DISTINCT
    volume_mount_point,
    CAST(total_bytes / 1073741824.0 AS DECIMAL(10,2)) AS total_gb,
    CAST(available_bytes / 1073741824.0 AS DECIMAL(10,2)) AS free_gb,
    CAST((total_bytes - available_bytes) * 100.0 / total_bytes AS DECIMAL(5,1)) AS used_pct
FROM sys.dm_os_volume_stats(DB_ID('master'), 1)
ORDER BY volume_mount_point;
"@
        $status.disk_drives = @($diskDt.Rows | ForEach-Object {
            @{ drive = $_.volume_mount_point; total_gb = [double]$_.total_gb; free_gb = [double]$_.free_gb; used_pct = [double]$_.used_pct }
        })

        # ── Connections & Blocking ─────────────────────────────────────────
        $connDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT
    COUNT(*) AS total_connections,
    SUM(CASE WHEN blocking_session_id > 0 THEN 1 ELSE 0 END) AS blocking_count
FROM sys.dm_exec_sessions
WHERE is_user_process = 1;
"@
        $status.open_connections = $connDt.Rows[0].total_connections
        $status.blocking_count   = $connDt.Rows[0].blocking_count

        # ── Databases ─────────────────────────────────────────────────────
        $dbDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT name, state_desc, recovery_model_desc,
       CAST(SUM(size) * 8.0 / 1048576 AS DECIMAL(10,2)) AS size_gb
FROM sys.databases d
JOIN sys.master_files f ON d.database_id = f.database_id
WHERE d.name NOT IN ('master','tempdb','model','msdb')
GROUP BY name, state_desc, recovery_model_desc
ORDER BY name;
"@
        $status.databases = @($dbDt.Rows | ForEach-Object {
            @{ name = $_.name; state = $_.state_desc; recovery_model = $_.recovery_model_desc; size_gb = [double]$_.size_gb }
        })

        # ── Last Backup ────────────────────────────────────────────────────
        $bkDt = Invoke-ServerQuery -Instance $Instance -Query @"
SELECT
    MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS last_full,
    MAX(CASE WHEN type = 'I' THEN backup_finish_date END) AS last_diff,
    MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS last_log
FROM msdb.dbo.backupset
WHERE database_name NOT IN ('master','tempdb','model','msdb')
  AND backup_finish_date > DATEADD(DAY, -7, GETDATE());
"@
        $status.last_backup      = @{
            full         = $bkDt.Rows[0].last_full?.ToString('o')
            differential = $bkDt.Rows[0].last_diff?.ToString('o')
            log          = $bkDt.Rows[0].last_log?.ToString('o')
        }
        $lastFull                = $bkDt.Rows[0].last_full
        $status.backup_age_hours = if ($lastFull) { [Math]::Round(((Get-Date) - $lastFull).TotalHours, 1) } else { 999 }

        # ── Determine Health ───────────────────────────────────────────────
        $alerts = @()
        if ($status.cpu_percent -gt 90)           { $alerts += "CPU critical: $($status.cpu_percent)%" }
        if ($status.memory_used_pct -gt 95)        { $alerts += "Memory critical: $($status.memory_used_pct)%" }
        if ($status.backup_age_hours -gt 24)       { $alerts += "Backup overdue: last full $($status.backup_age_hours)h ago" }
        if ($status.blocking_count -gt 10)         { $alerts += "High blocking: $($status.blocking_count) sessions" }
        foreach ($d in $status.disk_drives) {
            if ($d.used_pct -gt 90)                { $alerts += "Disk critical: $($d.drive) at $($d.used_pct)%" }
            elseif ($d.used_pct -gt 80)            { $alerts += "Disk warning: $($d.drive) at $($d.used_pct)%" }
        }
        $status.alerts = $alerts
        $status.health = if ($alerts.Count -eq 0) { 'Healthy' } elseif ($status.cpu_percent -gt 95 -or $status.memory_used_pct -gt 98) { 'Critical' } else { 'Degraded' }
    }
    catch {
        $status.reachable = $false
        $status.health    = 'Offline'
        $status.error     = $_.Exception.Message
        Write-StatusLog -Level 'ERROR' -Message "Failed to collect status from $Instance : $_"
    }

    return $status
}

# ─── Main ─────────────────────────────────────────────────────────────────────

$servers = @()

if ($ServerList -ne '') {
    $servers = $ServerList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}
elseif (-not $DryRun) {
    # Fetch from inventory
    try {
        $invDt  = Invoke-ServerQuery -Instance $InventoryServer -Query "SELECT InstanceName FROM RaaSInventory.dbo.ServerInventory WHERE IsActive = 1;" -Database 'master'
        $servers = @($invDt.Rows | ForEach-Object { $_.InstanceName })
        Write-StatusLog -Message "Loaded $($servers.Count) servers from inventory."
    }
    catch {
        Write-StatusLog -Level 'WARN' -Message "Could not query inventory server. Using default server list."
        $servers = @('SQL-PROD-01', 'SQL-STG-01')
    }
}
else {
    $servers = @('SQL-PROD-01', 'SQL-PROD-02', 'SQL-STG-01', 'SQL-UAT-01', 'SQL-QA-01', 'SQL-DEV-01')
}

$allStatus = @()

# Collect status for each server in parallel (PowerShell 7+) or sequentially (PS 5)
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $allStatus = $servers | ForEach-Object -Parallel {
        $fn = $using:Function:Get-SingleServerStatus
        & $fn -Instance $_
    } -ThrottleLimit 5
}
else {
    foreach ($srv in $servers) {
        $allStatus += Get-SingleServerStatus -Instance $srv
    }
}

$summary = @{
    collected_at     = (Get-Date -Format 'o')
    total_servers    = $allStatus.Count
    healthy_count    = ($allStatus | Where-Object { $_.health -eq 'Healthy' }).Count
    degraded_count   = ($allStatus | Where-Object { $_.health -eq 'Degraded' }).Count
    critical_count   = ($allStatus | Where-Object { $_.health -eq 'Critical' }).Count
    offline_count    = ($allStatus | Where-Object { $_.health -eq 'Offline' }).Count
    servers          = $allStatus
}

$summary | ConvertTo-Json -Depth 10
