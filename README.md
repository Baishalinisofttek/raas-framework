# RaaS Framework — SQL Restore-as-a-Service

A production-grade framework for orchestrating SQL Server restore operations with
AI-assisted governance, approval workflows, and real-time monitoring.

## Quick Start

### 1. Start the FastAPI Backend

```bash
cd agent
pip install -r requirements.txt
python raas_agent.py
# API running at http://localhost:8000
# Swagger docs at http://localhost:8000/docs
```

### 2. Open the UI

Open `ui/index.html` in a browser. The UI connects to `http://localhost:8000` by default.
To change the API URL, go to **Settings** in the sidebar.

---

## Project Structure

```
raas-framework/
├── agent/
│   ├── raas_agent.py        # FastAPI app + agent orchestration
│   ├── models.py            # Pydantic request/response models
│   ├── governance.py        # Rule-based governance engine
│   ├── mock_data.py         # Demo data (servers, jobs, alerts)
│   └── requirements.txt
├── powershell/
│   ├── Invoke-SqlRestore.ps1          # Main restore orchestrator
│   ├── Get-ServerStatus.ps1           # Server health collector
│   ├── Get-SpaceAlerts.ps1            # Disk space monitor
│   └── Validate-RestoreRequest.ps1    # Pre-execution validator
├── sql/
│   ├── sp_RegisterRestoreRequest.sql  # Audit logging procedure
│   ├── sp_ExecuteRestore.sql          # T-SQL restore executor
│   └── sp_GetRestoreAuditLog.sql      # Audit retrieval procedure
└── ui/
    ├── index.html           # Single-page app
    ├── styles.css           # Dark theme styles
    └── app.js               # Frontend logic (vanilla JS)
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Service health check |
| GET | `/servers` | List SQL Server inventory |
| GET | `/alerts` | Space & health alerts |
| GET | `/jobs` | List restore jobs |
| GET | `/dashboard` | KPI statistics |
| POST | `/restore/request` | Submit a new restore request |
| POST | `/restore/approve/{id}` | Approve or reject a request |
| POST | `/restore/execute/{id}` | Trigger execution of approved job |
| GET | `/restore/status/{id}` | Lightweight polling status |
| POST | `/agent/analyze` | AI agent natural language analysis |
| GET | `/audit/logs` | Audit trail |
| WS | `/ws/jobs/{id}` | Real-time job log stream |

---

## PowerShell Usage

```powershell
# Full restore with dry-run
.\Invoke-SqlRestore.ps1 `
    -SourceServer "SQL-PROD-01" `
    -TargetServer "SQL-UAT-01" `
    -DatabaseName "OrdersDB" `
    -RestoreType Full `
    -OverwriteExisting `
    -JobId "JOB-TEST-01" `
    -DryRun

# Server health check
.\Get-ServerStatus.ps1 -ServerList "SQL-PROD-01,SQL-STG-01" -DryRun

# Space alerts
.\Get-SpaceAlerts.ps1 -CriticalThresholdPct 90 -WarningThresholdPct 80 -DryRun

# Governance validation
.\Validate-RestoreRequest.ps1 `
    -SourceServer "SQL-PROD-01" `
    -TargetServer "SQL-UAT-01" `
    -DatabaseName "OrdersDB" `
    -Requestor "dba@company.com" `
    -Justification "UAT refresh for sprint-42 testing cycle" `
    -DryRun
```

---

## Governance Engine

Risk scoring is additive — each flag adds to the score:

| Flag | Points | Description |
|------|--------|-------------|
| `TARGET_IS_PRODUCTION` | +40 | Restoring to PROD |
| `PROD_TO_PROD_RESTORE` | +50 | PROD → PROD (hard block) |
| `UNAPPROVED_REQUESTOR` | +20 | Not on whitelist (hard block) |
| `INSUFFICIENT_JUSTIFICATION` | +25 | < 30 character justification |
| `OVERWRITE_EXISTING_DB` | +15 | Overwrite flag set |
| `OUTSIDE_BUSINESS_HOURS` | +10 | Sensitive env, off-hours |
| `IMMEDIATE_PRODUCTION_RESTORE` | +5 | Immediate exec on PROD |
| `LARGE_DATABASE` | +10 | > 50 GB database |

**Thresholds:** ≤30 = auto-approve, >30 = requires manual approval

---

## SQL Setup

Run stored procedures against the `RaaSInventory` database:

```sql
USE RaaSInventory;
GO
-- Run each file in the sql/ directory in order:
-- 1. sp_RegisterRestoreRequest.sql
-- 2. sp_ExecuteRestore.sql (on target server, against master)
-- 3. sp_GetRestoreAuditLog.sql
```
