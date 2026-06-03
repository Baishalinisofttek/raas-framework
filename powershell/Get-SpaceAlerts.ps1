<#
.SYNOPSIS
    RaaS Framework - Disk Space Alert Monitor
.DESCRIPTION
    Scans SQL Server instances for low disk space and generates
    structured alerts for the RaaS agent. Supports configurable
    thresholds and severity levels.
.PARAMETER ServerList
    Comma-separated list of server instances to check.
.PARAMETER CriticalThresholdPct
    Disk usage percentage above which a CRITICAL alert is raised. Default: 90
.PARAMETER WarningThresholdPct
    Disk usage percentage above which a WARNING alert is raised. Default: 80
.PARAMETER MinimumFreeGb
    Minimum free GB below which an alert is always raised. Default: 20
.PARAMETER DryRun
    Return simulated alert data.
.PARAMETER OutputPath
    Optional path to write the JSON alert report.
.EXAMPLE
    .\Get-SpaceAlerts.ps1 -ServerList "SQL-PROD-01,SQL-PROD-02" -CriticalThresholdPct 90
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ServerList = '',

    [Parameter()]
    [ValidateRange(50, 99)]
    [int]$CriticalThresholdPct = 90,

    [Parameter()]
    [ValidateRange(50, 99)]
    [int]$WarningThresholdPct = 80,

    [Parameter()]
    [double]$MinimumFreeGb = 20.0,

    [Parameter()]
    [int]$TimeoutSeconds = 15,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Logger ───────────────────────────────────────────────────────────────────

function Write-AlertLog {
    param([string]$Level = 'INFO', [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffZ'
    $color = switch ($Level) { 'CRITICAL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Gray' } }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ─── Space Check Per Server ───────────────────────────────────────────────────

function Get-ServerSpaceAlerts {
    param([string]$Instance)

    $alerts = @()

    if ($DryRun) {
        # Simulate realistic disk space data
        $simulatedDrives = @(
            @{ drive = 'C:'; total_gb = 100.0; free_gb = 35.0 }
            @{ drive = 'D:'; total_gb = 500.0; free_gb = 42.0 }
            @{ drive = 'E:'; total_gb = 2000.0; free_gb = 8.0 }
            @{ drive = 'L:'; total_gb = 200.0; free_gb = 120.0 }
        )

        foreach ($d in $simulatedDrives) {
            $usedPct = [Math]::Round(100 - ($d.free_gb / $d.total_gb * 100), 1)
            if ($usedPct -ge $CriticalThresholdPct -or $d.free_gb -lt $MinimumFreeGb) {
                $severity = if ($usedPct -ge $CriticalThresholdPct) { 'Critical' } else { 'Warning' }
                $alerts += @{
                    alert_id          = [System.Guid]::NewGuid().ToString()
                    server_name       = $Instance
                    drive             = $d.drive
                    severity          = $severity
                    free_gb           = $d.free_gb
                    total_gb          = $d.total_gb
                    used_percent      = $usedPct
                    threshold_percent = if ($severity -eq 'Critical') { $CriticalThresholdPct } else { $WarningThresholdPct }
                    created_at        = (Get-Date -Format 'o')
                    acknowledged      = $false
                    message           = "${severity}: Drive $($d.drive) on $Instance is at ${usedPct}% used ($($d.free_gb) GB free of $($d.total_gb) GB)"
                    recommended_action = if ($d.free_gb -lt 5) {
                        'URGENT: Immediate action required. Archive or move backup files.'
                    } elseif ($d.free_gb -lt $MinimumFreeGb) {
                        'Expand drive or archive old backup files within 24 hours.'
                    } else {
                        'Schedule disk cleanup or capacity expansion within 1 week.'
                    }
                }
            }
        }
        return $alerts
    }

    # ── Real disk space query via SQL Server DMV ──────────────────────────────
    $connStr = "Server=$Instance;Database=master;Integrated Security=True;Connect Timeout=$TimeoutSeconds;Application Name=RaaS-SpaceCheck;"
    $conn    = New-Object System.Data.SqlClient.SqlConnection $connStr

    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT DISTINCT
    volume_mount_point                                                  AS drive,
    CAST(total_bytes / 1073741824.0 AS DECIMAL(10,2))                  AS total_gb,
    CAST(available_bytes / 1073741824.0 AS DECIMAL(10,2))              AS free_gb,
    CAST((total_bytes - available_bytes) * 100.0 / total_bytes
         AS DECIMAL(5,1))                                               AS used_pct
FROM sys.dm_os_volume_stats(1, 1)
ORDER BY used_pct DESC;
"@
        $cmd.CommandTimeout = $TimeoutSeconds
        $reader = $cmd.ExecuteReader()
        $dt = New-Object System.Data.DataTable
        $dt.Load($reader)

        foreach ($row in $dt.Rows) {
            $drive   = $row.drive
            $totalGb = [double]$row.total_gb
            $freeGb  = [double]$row.free_gb
            $usedPct = [double]$row.used_pct

            $severity = $null
            if ($usedPct -ge $CriticalThresholdPct -or $freeGb -lt ($MinimumFreeGb / 2)) {
                $severity = 'Critical'
            }
            elseif ($usedPct -ge $WarningThresholdPct -or $freeGb -lt $MinimumFreeGb) {
                $severity = 'Warning'
            }

            if ($severity) {
                $threshold = if ($severity -eq 'Critical') { $CriticalThresholdPct } else { $WarningThresholdPct }
                $alerts += @{
                    alert_id          = [System.Guid]::NewGuid().ToString()
                    server_name       = $Instance
                    drive             = $drive
                    severity          = $severity
                    free_gb           = $freeGb
                    total_gb          = $totalGb
                    used_percent      = $usedPct
                    threshold_percent = $threshold
                    created_at        = (Get-Date -Format 'o')
                    acknowledged      = $false
                    message           = "${severity}: Drive $drive on $Instance is at ${usedPct}% used (${freeGb} GB free)"
                    recommended_action = if ($freeGb -lt 5) {
                        'URGENT: Immediate action required. Archive or move backup files.'
                    } else {
                        'Schedule disk cleanup or capacity expansion.'
                    }
                }
                Write-AlertLog -Level $severity.ToUpper() -Message "$($alerts[-1].message)"
            }
        }
    }
    catch {
        Write-AlertLog -Level 'ERROR' -Message "Failed to check space on $Instance : $($_.Exception.Message)"
        $alerts += @{
            alert_id     = [System.Guid]::NewGuid().ToString()
            server_name  = $Instance
            drive        = 'N/A'
            severity     = 'Warning'
            message      = "Could not collect disk info from $Instance : $($_.Exception.Message)"
            created_at   = (Get-Date -Format 'o')
            acknowledged = $false
        }
    }
    finally {
        $conn.Close()
    }

    return $alerts
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if ($ServerList -eq '') {
    # Default set for demo
    $servers = @('SQL-PROD-01', 'SQL-PROD-02', 'SQL-STG-01', 'SQL-UAT-01', 'SQL-QA-01', 'SQL-DEV-01', 'SQL-DR-01')
}
else {
    $servers = $ServerList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

Write-AlertLog -Message "Scanning $($servers.Count) server(s) for space alerts..."

$allAlerts = @()
foreach ($srv in $servers) {
    $srvAlerts = Get-ServerSpaceAlerts -Instance $srv
    $allAlerts += $srvAlerts
}

# Sort: Critical first, then by free_gb ascending
$sorted = $allAlerts | Sort-Object @{e = { if ($_.severity -eq 'Critical') { 0 } else { 1 } }; a = $true }, @{e = { $_.free_gb }; a = $true }

$report = @{
    generated_at     = (Get-Date -Format 'o')
    servers_scanned  = $servers.Count
    total_alerts     = $sorted.Count
    critical_count   = ($sorted | Where-Object { $_.severity -eq 'Critical' }).Count
    warning_count    = ($sorted | Where-Object { $_.severity -eq 'Warning' }).Count
    alerts           = $sorted
    thresholds       = @{
        critical_pct   = $CriticalThresholdPct
        warning_pct    = $WarningThresholdPct
        min_free_gb    = $MinimumFreeGb
    }
}

$json = $report | ConvertTo-Json -Depth 10

if ($OutputPath -ne '') {
    $json | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-AlertLog -Message "Alert report written to $OutputPath"
}

Write-Output $json
