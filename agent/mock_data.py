"""
Mock data for the RaaS Framework demo.
Simulates a SQL Server inventory, active jobs, space alerts, and audit logs.
"""
from datetime import datetime, timedelta
from typing import Dict, List
import random
import uuid

from models import (
    ServerInfo, SpaceAlert, RestoreJob, AuditEntry,
    EnvironmentTier, ServerHealth, AlertSeverity,
    JobStatus, RestoreRequest, RestoreType, ScheduleType, JobLog
)


# ─── Server Inventory ─────────────────────────────────────────────────────────

SERVERS: Dict[str, ServerInfo] = {
    "SQL-PROD-01": ServerInfo(
        server_name="SQL-PROD-01",
        instance_name="SQL-PROD-01\\MSSQLSERVER",
        environment=EnvironmentTier.PRODUCTION,
        version="SQL Server 2022",
        edition="Enterprise Edition",
        health=ServerHealth.HEALTHY,
        cpu_percent=34.5,
        memory_percent=68.2,
        disk_free_gb=480.0,
        disk_total_gb=2000.0,
        last_backup=datetime.utcnow() - timedelta(hours=2),
        is_source_eligible=True,
        is_target_eligible=False,
        databases=["OrdersDB", "CustomerDB", "InventoryDB", "FinanceDB", "HRDB"],
        tags={"owner": "DBA Team", "criticality": "P1", "region": "US-East"},
    ),
    "SQL-PROD-02": ServerInfo(
        server_name="SQL-PROD-02",
        instance_name="SQL-PROD-02\\MSSQLSERVER",
        environment=EnvironmentTier.PRODUCTION,
        version="SQL Server 2022",
        edition="Enterprise Edition",
        health=ServerHealth.DEGRADED,
        cpu_percent=78.1,
        memory_percent=89.4,
        disk_free_gb=42.0,
        disk_total_gb=1000.0,
        last_backup=datetime.utcnow() - timedelta(hours=6),
        is_source_eligible=True,
        is_target_eligible=False,
        databases=["ReportingDB", "AnalyticsDB", "DataWarehouseDB"],
        tags={"owner": "Analytics Team", "criticality": "P1", "region": "US-East"},
    ),
    "SQL-STG-01": ServerInfo(
        server_name="SQL-STG-01",
        instance_name="SQL-STG-01\\MSSQLSERVER",
        environment=EnvironmentTier.STAGING,
        version="SQL Server 2022",
        edition="Standard Edition",
        health=ServerHealth.HEALTHY,
        cpu_percent=22.0,
        memory_percent=45.0,
        disk_free_gb=320.0,
        disk_total_gb=500.0,
        last_backup=datetime.utcnow() - timedelta(hours=12),
        is_source_eligible=True,
        is_target_eligible=True,
        databases=["OrdersDB", "CustomerDB", "InventoryDB"],
        tags={"owner": "DBA Team", "criticality": "P2", "region": "US-East"},
    ),
    "SQL-UAT-01": ServerInfo(
        server_name="SQL-UAT-01",
        instance_name="SQL-UAT-01\\MSSQLSERVER",
        environment=EnvironmentTier.UAT,
        version="SQL Server 2019",
        edition="Developer Edition",
        health=ServerHealth.HEALTHY,
        cpu_percent=15.0,
        memory_percent=38.5,
        disk_free_gb=150.0,
        disk_total_gb=500.0,
        last_backup=datetime.utcnow() - timedelta(days=1),
        is_source_eligible=False,
        is_target_eligible=True,
        databases=["OrdersDB", "CustomerDB"],
        tags={"owner": "QA Team", "criticality": "P3", "region": "US-West"},
    ),
    "SQL-QA-01": ServerInfo(
        server_name="SQL-QA-01",
        instance_name="SQL-QA-01\\MSSQLSERVER",
        environment=EnvironmentTier.QA,
        version="SQL Server 2019",
        edition="Developer Edition",
        health=ServerHealth.HEALTHY,
        cpu_percent=10.5,
        memory_percent=32.0,
        disk_free_gb=200.0,
        disk_total_gb=500.0,
        last_backup=datetime.utcnow() - timedelta(days=2),
        is_source_eligible=False,
        is_target_eligible=True,
        databases=["OrdersDB", "CustomerDB", "InventoryDB"],
        tags={"owner": "QA Team", "criticality": "P3", "region": "US-West"},
    ),
    "SQL-DEV-01": ServerInfo(
        server_name="SQL-DEV-01",
        instance_name="SQL-DEV-01\\MSSQLSERVER",
        environment=EnvironmentTier.DEV,
        version="SQL Server 2019",
        edition="Developer Edition",
        health=ServerHealth.HEALTHY,
        cpu_percent=8.0,
        memory_percent=28.0,
        disk_free_gb=350.0,
        disk_total_gb=500.0,
        last_backup=datetime.utcnow() - timedelta(days=3),
        is_source_eligible=False,
        is_target_eligible=True,
        databases=["OrdersDB", "TestDB", "DevDB"],
        tags={"owner": "Dev Team", "criticality": "P4", "region": "US-West"},
    ),
    "SQL-DR-01": ServerInfo(
        server_name="SQL-DR-01",
        instance_name="SQL-DR-01\\MSSQLSERVER",
        environment=EnvironmentTier.PRODUCTION,
        version="SQL Server 2022",
        edition="Enterprise Edition",
        health=ServerHealth.CRITICAL,
        cpu_percent=95.0,
        memory_percent=97.5,
        disk_free_gb=8.0,
        disk_total_gb=2000.0,
        last_backup=datetime.utcnow() - timedelta(days=1),
        is_source_eligible=False,
        is_target_eligible=False,
        databases=["OrdersDB", "CustomerDB", "InventoryDB", "FinanceDB"],
        tags={"owner": "DBA Team", "criticality": "P1", "region": "US-DR"},
    ),
}


# ─── Space Alerts ─────────────────────────────────────────────────────────────

def _make_alert(
    server: str, drive: str, free_gb: float, total_gb: float,
    threshold: float, acknowledged: bool = False
) -> SpaceAlert:
    used = total_gb - free_gb
    used_pct = round((used / total_gb) * 100, 1)
    if used_pct >= 95:
        sev = AlertSeverity.CRITICAL
        msg = f"CRITICAL: Drive {drive} on {server} is nearly full ({used_pct}% used, {free_gb:.1f} GB free)"
    elif used_pct >= 85:
        sev = AlertSeverity.WARNING
        msg = f"WARNING: Drive {drive} on {server} has low free space ({used_pct}% used, {free_gb:.1f} GB free)"
    else:
        sev = AlertSeverity.INFO
        msg = f"INFO: Drive {drive} on {server} space usage at {used_pct}%"

    return SpaceAlert(
        alert_id=str(uuid.uuid4()),
        server_name=server,
        drive=drive,
        severity=sev,
        free_gb=free_gb,
        total_gb=total_gb,
        used_percent=used_pct,
        threshold_percent=threshold,
        created_at=datetime.utcnow() - timedelta(minutes=random.randint(5, 360)),
        acknowledged=acknowledged,
        message=msg,
    )


SPACE_ALERTS: List[SpaceAlert] = [
    _make_alert("SQL-DR-01", "E:", 8.0, 2000.0, 90.0),
    _make_alert("SQL-PROD-02", "D:", 42.0, 1000.0, 85.0),
    _make_alert("SQL-STG-01", "F:", 25.0, 500.0, 85.0),
    _make_alert("SQL-UAT-01", "D:", 45.0, 500.0, 85.0, acknowledged=True),
    _make_alert("SQL-DEV-01", "E:", 50.0, 500.0, 80.0, acknowledged=True),
]


# ─── Pre-seeded Restore Jobs ──────────────────────────────────────────────────

def _make_logs(messages: List[tuple]) -> List[JobLog]:
    base = datetime.utcnow() - timedelta(hours=1)
    logs = []
    for i, (level, msg, source) in enumerate(messages):
        logs.append(JobLog(
            timestamp=base + timedelta(seconds=i * 15),
            level=level,
            message=msg,
            source=source,
        ))
    return logs


_COMPLETED_LOGS = _make_logs([
    ("INFO", "Restore request received and validated.", "Governance"),
    ("INFO", "Connecting to SQL-PROD-01 to locate backup chain.", "Agent"),
    ("INFO", "Backup chain identified: Full backup at 2024-01-15 02:00 UTC (Size: 18.4 GB).", "Agent"),
    ("INFO", "Pre-flight checks passed: target server SQL-UAT-01 has 150 GB free space.", "PowerShell"),
    ("INFO", "Executing Invoke-SqlRestore.ps1 on SQL-UAT-01.", "PowerShell"),
    ("INFO", "RESTORE DATABASE [OrdersDB] progress: 25%", "PowerShell"),
    ("INFO", "RESTORE DATABASE [OrdersDB] progress: 50%", "PowerShell"),
    ("INFO", "RESTORE DATABASE [OrdersDB] progress: 75%", "PowerShell"),
    ("INFO", "RESTORE DATABASE [OrdersDB] progress: 100%", "PowerShell"),
    ("INFO", "Post-restore validation: DBCC CHECKDB passed with 0 errors.", "PowerShell"),
    ("INFO", "Restore completed successfully. Duration: 8m 32s.", "Agent"),
])

_FAILED_LOGS = _make_logs([
    ("INFO", "Restore request received.", "Governance"),
    ("INFO", "Connecting to SQL-PROD-01...", "Agent"),
    ("INFO", "Backup chain identified: Last full backup 6 hours ago.", "Agent"),
    ("WARN", "Target server SQL-PROD-02 CPU is at 78% — elevated load.", "Agent"),
    ("INFO", "Executing Invoke-SqlRestore.ps1...", "PowerShell"),
    ("ERROR", "RESTORE DATABASE [AnalyticsDB] failed: Insufficient disk space on target. Required: 220 GB, Available: 42 GB.", "PowerShell"),
    ("ERROR", "Restore aborted. Cleanup initiated on target server.", "PowerShell"),
])

_RUNNING_LOGS = _make_logs([
    ("INFO", "Restore request approved by DBA Lead.", "Governance"),
    ("INFO", "Initiating restore workflow for ReportingDB.", "Agent"),
    ("INFO", "Full backup located: SQL-PROD-01 backup share \\\\backup\\PROD\\ReportingDB_20240115.bak (Size: 35.2 GB).", "Agent"),
    ("INFO", "Pre-flight checks passed.", "PowerShell"),
    ("INFO", "RESTORE DATABASE [ReportingDB] progress: 45%", "PowerShell"),
])

_PENDING_LOGS = _make_logs([
    ("INFO", "Restore request received.", "Governance"),
    ("INFO", "Risk score: 65 (Medium). Requires DBA Lead approval.", "Governance"),
    ("WARN", "Target environment is Staging — manual approval required.", "Governance"),
])

now = datetime.utcnow()

RESTORE_JOBS: Dict[str, RestoreJob] = {
    "JOB-001": RestoreJob(
        job_id="JOB-001",
        restore_request=RestoreRequest(
            source_server="SQL-PROD-01",
            target_server="SQL-UAT-01",
            database_name="OrdersDB",
            restore_type=RestoreType.FULL,
            schedule_type=ScheduleType.IMMEDIATE,
            justification="QA team needs production data refresh for UAT cycle 2024-01-15. Approved under change ticket CHG-4421.",
            requestor="jane.doe@company.com",
            overwrite_existing=True,
            governance_acknowledged=True,
        ),
        status=JobStatus.COMPLETED,
        created_at=now - timedelta(hours=3),
        updated_at=now - timedelta(hours=2),
        approved_at=now - timedelta(hours=2, minutes=50),
        approver="dba@company.com",
        started_at=now - timedelta(hours=2, minutes=45),
        completed_at=now - timedelta(hours=2, minutes=37),
        duration_seconds=512,
        risk_score=35,
        governance_flags=["OVERWRITE_EXISTING_DB"],
        logs=_COMPLETED_LOGS,
        progress_percent=100,
    ),
    "JOB-002": RestoreJob(
        job_id="JOB-002",
        restore_request=RestoreRequest(
            source_server="SQL-PROD-01",
            target_server="SQL-PROD-02",
            database_name="AnalyticsDB",
            restore_type=RestoreType.FULL,
            schedule_type=ScheduleType.IMMEDIATE,
            justification="Emergency restore due to data corruption detected on AnalyticsDB.",
            requestor="dba@company.com",
            overwrite_existing=True,
            governance_acknowledged=True,
        ),
        status=JobStatus.FAILED,
        created_at=now - timedelta(hours=5),
        updated_at=now - timedelta(hours=4, minutes=30),
        approved_at=now - timedelta(hours=4, minutes=55),
        approver="admin@company.com",
        started_at=now - timedelta(hours=4, minutes=45),
        completed_at=now - timedelta(hours=4, minutes=38),
        duration_seconds=420,
        error_message="Insufficient disk space on target server SQL-PROD-02. Required 220 GB, available 42 GB.",
        risk_score=85,
        governance_flags=["TARGET_IS_PRODUCTION", "OVERWRITE_EXISTING_DB", "IMMEDIATE_PRODUCTION_RESTORE"],
        logs=_FAILED_LOGS,
        progress_percent=0,
    ),
    "JOB-003": RestoreJob(
        job_id="JOB-003",
        restore_request=RestoreRequest(
            source_server="SQL-PROD-01",
            target_server="SQL-STG-01",
            database_name="ReportingDB",
            restore_type=RestoreType.FULL,
            schedule_type=ScheduleType.IMMEDIATE,
            justification="Staging environment refresh for pre-release testing of v3.2 release. PM approved via JIRA-8812.",
            requestor="john.smith@company.com",
            overwrite_existing=True,
            governance_acknowledged=True,
        ),
        status=JobStatus.RUNNING,
        created_at=now - timedelta(minutes=45),
        updated_at=now - timedelta(minutes=5),
        approved_at=now - timedelta(minutes=40),
        approver="dba@company.com",
        started_at=now - timedelta(minutes=35),
        risk_score=45,
        governance_flags=["OVERWRITE_EXISTING_DB"],
        logs=_RUNNING_LOGS,
        progress_percent=45,
    ),
    "JOB-004": RestoreJob(
        job_id="JOB-004",
        restore_request=RestoreRequest(
            source_server="SQL-STG-01",
            target_server="SQL-QA-01",
            database_name="CustomerDB",
            restore_type=RestoreType.DIFFERENTIAL,
            schedule_type=ScheduleType.SCHEDULED,
            scheduled_time=now + timedelta(hours=2),
            justification="Scheduled differential refresh for QA regression suite. Ticket: QA-3301.",
            requestor="ops-team@company.com",
            overwrite_existing=False,
            governance_acknowledged=True,
        ),
        status=JobStatus.AWAITING_APPROVAL,
        created_at=now - timedelta(minutes=20),
        updated_at=now - timedelta(minutes=20),
        risk_score=65,
        governance_flags=["OUTSIDE_BUSINESS_HOURS"],
        logs=_PENDING_LOGS,
        progress_percent=0,
    ),
    "JOB-005": RestoreJob(
        job_id="JOB-005",
        restore_request=RestoreRequest(
            source_server="SQL-PROD-01",
            target_server="SQL-DEV-01",
            database_name="OrdersDB",
            restore_type=RestoreType.FULL,
            schedule_type=ScheduleType.IMMEDIATE,
            justification="Dev team needs production schema snapshot for sprint-42 feature development and testing.",
            requestor="dba.team@corp.internal",
            overwrite_existing=True,
            governance_acknowledged=True,
        ),
        status=JobStatus.APPROVED,
        created_at=now - timedelta(minutes=10),
        updated_at=now - timedelta(minutes=5),
        approved_at=now - timedelta(minutes=5),
        approver="dba@company.com",
        risk_score=20,
        governance_flags=[],
        logs=_make_logs([
            ("INFO", "Restore request received and auto-approved (risk score: 20).", "Governance"),
            ("INFO", "Waiting for execution slot.", "Agent"),
        ]),
        progress_percent=0,
    ),
}


# ─── Audit Log ────────────────────────────────────────────────────────────────

AUDIT_LOG: List[AuditEntry] = [
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-001",
        action="RESTORE_REQUEST_CREATED",
        actor="jane.doe@company.com",
        timestamp=now - timedelta(hours=3),
        details={"source": "SQL-PROD-01", "target": "SQL-UAT-01", "database": "OrdersDB"},
        ip_address="10.0.1.45",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-001",
        action="GOVERNANCE_VALIDATED",
        actor="System",
        timestamp=now - timedelta(hours=3),
        details={"risk_score": 35, "flags": ["OVERWRITE_EXISTING_DB"]},
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-001",
        action="RESTORE_APPROVED",
        actor="dba@company.com",
        timestamp=now - timedelta(hours=2, minutes=50),
        details={"notes": "Approved — change ticket CHG-4421 verified."},
        ip_address="10.0.1.10",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-001",
        action="RESTORE_EXECUTED",
        actor="System",
        timestamp=now - timedelta(hours=2, minutes=45),
        details={"powershell_script": "Invoke-SqlRestore.ps1", "duration_seconds": 512},
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-001",
        action="RESTORE_COMPLETED",
        actor="System",
        timestamp=now - timedelta(hours=2, minutes=37),
        details={"dbcc_check": "PASSED", "pages_restored": 184320},
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-002",
        action="RESTORE_REQUEST_CREATED",
        actor="dba@company.com",
        timestamp=now - timedelta(hours=5),
        details={"source": "SQL-PROD-01", "target": "SQL-PROD-02", "database": "AnalyticsDB"},
        ip_address="10.0.1.10",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-002",
        action="RESTORE_FAILED",
        actor="System",
        timestamp=now - timedelta(hours=4, minutes=38),
        details={"error": "Insufficient disk space", "required_gb": 220, "available_gb": 42},
        result="Failure",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-003",
        action="RESTORE_REQUEST_CREATED",
        actor="john.smith@company.com",
        timestamp=now - timedelta(minutes=45),
        details={"source": "SQL-PROD-01", "target": "SQL-STG-01", "database": "ReportingDB"},
        ip_address="10.0.2.88",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-003",
        action="RESTORE_APPROVED",
        actor="dba@company.com",
        timestamp=now - timedelta(minutes=40),
        details={"notes": "Approved for pre-release staging refresh."},
        ip_address="10.0.1.10",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-004",
        action="RESTORE_REQUEST_CREATED",
        actor="ops-team@company.com",
        timestamp=now - timedelta(minutes=20),
        details={"source": "SQL-STG-01", "target": "SQL-QA-01", "database": "CustomerDB"},
        ip_address="10.0.3.12",
        result="Pending",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-005",
        action="RESTORE_REQUEST_CREATED",
        actor="dba.team@corp.internal",
        timestamp=now - timedelta(minutes=10),
        details={"source": "SQL-PROD-01", "target": "SQL-DEV-01", "database": "OrdersDB"},
        ip_address="10.0.1.15",
        result="Success",
    ),
    AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id="JOB-005",
        action="RESTORE_AUTO_APPROVED",
        actor="System",
        timestamp=now - timedelta(minutes=9),
        details={"reason": "Risk score 20 — below auto-approve threshold of 30", "risk_score": 20},
        result="Success",
    ),
]
