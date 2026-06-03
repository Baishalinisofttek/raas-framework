<#
.SYNOPSIS
    RaaS Framework - Restore Request Governance Validator
.DESCRIPTION
    Pre-execution validation script that checks governance rules, environment
    policies, and infrastructure readiness before a restore is attempted.
    Designed to be called by the Python agent OR independently.
.PARAMETER JobId
    Unique RaaS job identifier.
.PARAMETER SourceServer
    Source SQL Server instance name.
.PARAMETER TargetServer
    Target SQL Server instance name.
.PARAMETER DatabaseName
    Database to be restored.
.PARAMETER RestoreType
    Full | Differential | Log
.PARAMETER Requestor
    Email of the requestor.
.PARAMETER Justification
    Business justification text.
.PARAMETER OverwriteExisting
    Whether the restore will overwrite an existing database.
.PARAMETER GovernanceAcknowledged
    Whether the requestor acknowledged the governance checklist.
.PARAMETER DryRun
    Skip all real connectivity checks.
.EXAMPLE
    .\Validate-RestoreRequest.ps1 -SourceServer SQL-PROD-01 -TargetServer SQL-UAT-01 `
        -DatabaseName OrdersDB -Requestor dba@company.com -Justification "UAT refresh for sprint 42"
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$JobId = [System.Guid]::NewGuid().ToString().Substring(0, 8).ToUpper(),

    [Parameter(Mandatory)]
    [string]$SourceServer,

    [Parameter(Mandatory)]
    [string]$TargetServer,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_\-]{1,128}$')]
    [string]$DatabaseName,

    [Parameter()]
    [ValidateSet('Full', 'Differential', 'Log')]
    [string]$RestoreType = 'Full',

    [Parameter()]
    [string]$Requestor = '',

    [Parameter()]
    [string]$Justification = '',

    [Parameter()]
    [switch]$OverwriteExisting,

    [Parameter()]
    [switch]$GovernanceAcknowledged,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Governance Configuration ─────────────────────────────────────────────────

$Config = @{
    ApprovedDomains       = @('company.com', 'corp.internal', 'dba-team.local')
    ApprovedRequestors    = @('dba@company.com', 'admin@company.com', 'restore-svc@company.com', 'ops-team@company.com')
    ProductionPatterns    = @('*-PROD-*', 'PROD*', '*\PROD')
    StagingPatterns       = @('*-STG-*', '*-STAGING-*')
    BusinessHoursStart    = 7   # UTC hour
    BusinessHoursEnd      = 18  # UTC hour
    MinJustificationChars = 30
    AutoApproveRiskMax    = 30  # Risk scores at or below this auto-approve
}

# ─── Logger ───────────────────────────────────────────────────────────────────

$script:ValidationLog = [System.Collections.Generic.List[hashtable]]::new()

function Write-ValLog {
    param([string]$Level = 'INFO', [string]$Rule, [string]$Message, [string]$Result = '')
    $entry = @{
        timestamp = (Get-Date -Format 'o')
        level     = $Level
        rule      = $Rule
        message   = $Message
        result    = $Result
    }
    $script:ValidationLog.Add($entry)
    $color = switch ($Level) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Gray' } }
    Write-Host "  [$Level] [$Rule] $Message" -ForegroundColor $color
}

# ─── Individual Rule Checks ───────────────────────────────────────────────────

function Test-RequestorWhitelist {
    if ($Requestor -eq '') {
        Write-ValLog -Level 'FAIL' -Rule 'REQUESTOR_WHITELIST' -Message 'No requestor specified.' -Result 'FAIL'
        return @{ passed = $false; points = 20; flag = 'UNAPPROVED_REQUESTOR' }
    }
    $domain = if ($Requestor -like '*@*') { $Requestor.Split('@')[1] } else { '' }
    $approved = ($Requestor -in $Config.ApprovedRequestors) -or ($domain -in $Config.ApprovedDomains)
    if ($approved) {
        Write-ValLog -Level 'PASS' -Rule 'REQUESTOR_WHITELIST' -Message "Requestor '$Requestor' is approved." -Result 'PASS'
        return @{ passed = $true; points = 0; flag = $null }
    }
    else {
        Write-ValLog -Level 'FAIL' -Rule 'REQUESTOR_WHITELIST' -Message "Requestor '$Requestor' not in approved list or domain." -Result 'FAIL'
        return @{ passed = $false; points = 20; flag = 'UNAPPROVED_REQUESTOR' }
    }
}

function Test-JustificationQuality {
    $len = $Justification.Trim().Length
    if ($len -ge $Config.MinJustificationChars) {
        Write-ValLog -Level 'PASS' -Rule 'JUSTIFICATION' -Message "Justification length $len chars — sufficient." -Result 'PASS'
        return @{ passed = $true; points = 0; flag = $null }
    }
    Write-ValLog -Level 'FAIL' -Rule 'JUSTIFICATION' -Message "Justification too short ($len chars). Minimum: $($Config.MinJustificationChars)." -Result 'FAIL'
    return @{ passed = $false; points = 25; flag = 'INSUFFICIENT_JUSTIFICATION' }
}

function Test-GovernanceAcknowledgement {
    if ($GovernanceAcknowledged) {
        Write-ValLog -Level 'PASS' -Rule 'GOVERNANCE_ACK' -Message 'Governance checklist acknowledged.' -Result 'PASS'
        return @{ passed = $true; points = 0; flag = $null }
    }
    Write-ValLog -Level 'WARN' -Rule 'GOVERNANCE_ACK' -Message 'Governance checklist not acknowledged by requestor.' -Result 'WARN'
    return @{ passed = $false; points = 5; flag = 'GOVERNANCE_NOT_ACKNOWLEDGED' }
}

function Test-ProductionTarget {
    $isProd = $false
    foreach ($p in $Config.ProductionPatterns) {
        if ($TargetServer -like $p) { $isProd = $true; break }
    }
    if ($isProd) {
        Write-ValLog -Level 'WARN' -Rule 'PRODUCTION_TARGET' -Message "Target '$TargetServer' matches PRODUCTION pattern. Elevated approval required." -Result 'WARN'
        return @{ passed = $false; points = 40; flag = 'TARGET_IS_PRODUCTION' }
    }
    Write-ValLog -Level 'PASS' -Rule 'PRODUCTION_TARGET' -Message "Target '$TargetServer' is not a production server." -Result 'PASS'
    return @{ passed = $true; points = 0; flag = $null }
}

function Test-ProdToProd {
    $srcProd = $false; $tgtProd = $false
    foreach ($p in $Config.ProductionPatterns) {
        if ($SourceServer -like $p) { $srcProd = $true }
        if ($TargetServer -like $p) { $tgtProd = $true }
    }
    if ($srcProd -and $tgtProd) {
        Write-ValLog -Level 'FAIL' -Rule 'PROD_TO_PROD' -Message 'Production-to-production restore detected. CAB approval mandatory.' -Result 'FAIL'
        return @{ passed = $false; points = 50; flag = 'PROD_TO_PROD_RESTORE' }
    }
    Write-ValLog -Level 'PASS' -Rule 'PROD_TO_PROD' -Message 'Not a production-to-production restore.' -Result 'PASS'
    return @{ passed = $true; points = 0; flag = $null }
}

function Test-BusinessHours {
    $hour = (Get-Date).ToUniversalTime().Hour
    $inHours = ($hour -ge $Config.BusinessHoursStart -and $hour -le $Config.BusinessHoursEnd)
    $isProd = $false
    foreach ($p in $Config.ProductionPatterns + $Config.StagingPatterns) {
        if ($TargetServer -like $p) { $isProd = $true; break }
    }
    if (-not $inHours -and $isProd) {
        Write-ValLog -Level 'WARN' -Rule 'BUSINESS_HOURS' -Message "Outside business hours (current UTC hour: $hour). Sensitive target requires change window." -Result 'WARN'
        return @{ passed = $false; points = 10; flag = 'OUTSIDE_BUSINESS_HOURS' }
    }
    Write-ValLog -Level 'PASS' -Rule 'BUSINESS_HOURS' -Message "Business hours check passed (UTC $($Config.BusinessHoursStart):00 – $($Config.BusinessHoursEnd):00)." -Result 'PASS'
    return @{ passed = $true; points = 0; flag = $null }
}

function Test-OverwriteRisk {
    if ($OverwriteExisting) {
        Write-ValLog -Level 'WARN' -Rule 'OVERWRITE_RISK' -Message 'OVERWRITE mode active — existing database data will be destroyed.' -Result 'WARN'
        return @{ passed = $false; points = 15; flag = 'OVERWRITE_EXISTING_DB' }
    }
    Write-ValLog -Level 'PASS' -Rule 'OVERWRITE_RISK' -Message 'No overwrite — target database will be treated as new.' -Result 'PASS'
    return @{ passed = $true; points = 0; flag = $null }
}

function Test-ServerConnectivity {
    if ($DryRun) {
        Write-ValLog -Level 'PASS' -Rule 'CONNECTIVITY' -Message '[DryRun] Skipping real connectivity test.' -Result 'PASS'
        return @{ passed = $true; points = 0; flag = $null }
    }
    $errors = @()
    foreach ($srv in @($SourceServer, $TargetServer)) {
        $host = $srv.Split('\')[0]
        $ok = Test-NetConnection -ComputerName $host -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($ok) {
            Write-ValLog -Level 'PASS' -Rule 'CONNECTIVITY' -Message "Reachable: $srv:1433" -Result 'PASS'
        }
        else {
            Write-ValLog -Level 'FAIL' -Rule 'CONNECTIVITY' -Message "Cannot reach $srv on port 1433." -Result 'FAIL'
            $errors += $srv
        }
    }
    if ($errors.Count -gt 0) {
        return @{ passed = $false; points = 0; flag = 'SERVER_UNREACHABLE'; detail = $errors }
    }
    return @{ passed = $true; points = 0; flag = $null }
}

# ─── Main Validation Runner ───────────────────────────────────────────────────

Write-Host ""
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host " RaaS Governance Validator — Job: $JobId" -ForegroundColor Magenta
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host " Source  : $SourceServer" -ForegroundColor White
Write-Host " Target  : $TargetServer" -ForegroundColor White
Write-Host " Database: $DatabaseName ($RestoreType)" -ForegroundColor White
Write-Host ""

$riskScore  = 0
$flags      = @()
$ruleResults = @()

$checks = @(
    { Test-RequestorWhitelist },
    { Test-JustificationQuality },
    { Test-GovernanceAcknowledgement },
    { Test-ProductionTarget },
    { Test-ProdToProd },
    { Test-BusinessHours },
    { Test-OverwriteRisk },
    { Test-ServerConnectivity }
)

foreach ($check in $checks) {
    $r = & $check
    $riskScore += $r.points
    if ($r.flag) { $flags += $r.flag }
    $ruleResults += $r
}

$riskScore = [Math]::Min($riskScore, 100)

$riskLabel = if ($riskScore -le 30)     { 'Low' }
             elseif ($riskScore -le 60) { 'Medium' }
             elseif ($riskScore -le 80) { 'High' }
             else                       { 'Critical' }

$hardBlocks  = @('UNAPPROVED_REQUESTOR', 'PROD_TO_PROD_RESTORE', 'SERVER_UNREACHABLE')
$hasHardBlock = ($flags | Where-Object { $_ -in $hardBlocks }).Count -gt 0

$overallPass = (-not $hasHardBlock) -and ($riskScore -le $Config.AutoApproveRiskMax)
$requiresApproval = (-not $overallPass) -and (-not $hasHardBlock)

Write-Host ""
Write-Host "── Validation Summary ──────────────────────────" -ForegroundColor Magenta
Write-Host " Risk Score  : $riskScore / 100 ($riskLabel)" -ForegroundColor $(if ($riskScore -le 30) { 'Green' } elseif ($riskScore -le 60) { 'Yellow' } else { 'Red' })
Write-Host " Flags       : $($flags -join ', ')" -ForegroundColor $(if ($flags.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-Host " Hard Blocks : $hasHardBlock" -ForegroundColor $(if ($hasHardBlock) { 'Red' } else { 'Green' })
Write-Host " Decision    : $(if ($overallPass) { 'AUTO-APPROVED' } elseif ($requiresApproval) { 'REQUIRES APPROVAL' } else { 'BLOCKED' })" -ForegroundColor $(if ($overallPass) { 'Green' } elseif ($requiresApproval) { 'Yellow' } else { 'Red' })
Write-Host ""

$result = @{
    job_id              = $JobId
    source_server       = $SourceServer
    target_server       = $TargetServer
    database_name       = $DatabaseName
    restore_type        = $RestoreType
    requestor           = $Requestor
    validated_at        = (Get-Date -Format 'o')
    risk_score          = $riskScore
    risk_label          = $riskLabel
    governance_flags    = $flags
    has_hard_block      = $hasHardBlock
    overall_passed      = $overallPass
    requires_approval   = $requiresApproval
    decision            = if ($overallPass) { 'AUTO_APPROVED' } elseif ($requiresApproval) { 'REQUIRES_APPROVAL' } else { 'BLOCKED' }
    logs                = $script:ValidationLog
}

$result | ConvertTo-Json -Depth 10
