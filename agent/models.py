"""
Pydantic models for the RaaS Framework API.
"""
from pydantic import BaseModel, Field, validator
from typing import Optional, List, Literal, Dict, Any
from datetime import datetime
from enum import Enum


class RestoreType(str, Enum):
    FULL = "Full"
    DIFFERENTIAL = "Differential"
    LOG = "Log"


class ScheduleType(str, Enum):
    IMMEDIATE = "Immediate"
    SCHEDULED = "Scheduled"


class JobStatus(str, Enum):
    PENDING = "Pending"
    AWAITING_APPROVAL = "AwaitingApproval"
    APPROVED = "Approved"
    REJECTED = "Rejected"
    RUNNING = "Running"
    COMPLETED = "Completed"
    FAILED = "Failed"
    CANCELLED = "Cancelled"


class AlertSeverity(str, Enum):
    CRITICAL = "Critical"
    WARNING = "Warning"
    INFO = "Info"


class EnvironmentTier(str, Enum):
    PRODUCTION = "Production"
    STAGING = "Staging"
    UAT = "UAT"
    QA = "QA"
    DEV = "Development"


class ServerHealth(str, Enum):
    HEALTHY = "Healthy"
    DEGRADED = "Degraded"
    CRITICAL = "Critical"
    OFFLINE = "Offline"


# ─── Request / Response Models ────────────────────────────────────────────────

class RestoreRequest(BaseModel):
    source_server: str = Field(..., description="Source SQL Server instance name")
    target_server: str = Field(..., description="Target SQL Server instance name")
    database_name: str = Field(..., description="Database to restore")
    restore_type: RestoreType = Field(default=RestoreType.FULL)
    schedule_type: ScheduleType = Field(default=ScheduleType.IMMEDIATE)
    scheduled_time: Optional[datetime] = Field(None, description="Schedule time if not immediate")
    justification: str = Field(..., min_length=20, description="Business justification")
    requestor: str = Field(..., description="Requestor email or username")
    backup_path: Optional[str] = Field(None, description="Override backup file path")
    overwrite_existing: bool = Field(default=False)
    governance_acknowledged: bool = Field(default=False)

    @validator("requestor")
    def validate_requestor(cls, v: str) -> str:
        if "@" not in v and "." not in v:
            raise ValueError("Requestor must be a valid email address")
        return v.lower()

    @validator("database_name")
    def validate_db_name(cls, v: str) -> str:
        import re
        if not re.match(r"^[A-Za-z0-9_\-]{1,128}$", v):
            raise ValueError("Invalid database name format")
        return v


class ApprovalRequest(BaseModel):
    approved: bool
    approver: str
    notes: Optional[str] = None


class AgentAnalyzeRequest(BaseModel):
    query: str = Field(..., description="Natural language query or request to analyze")
    context: Optional[Dict[str, Any]] = Field(default_factory=dict)


# ─── Data Models ──────────────────────────────────────────────────────────────

class ServerInfo(BaseModel):
    server_name: str
    instance_name: str
    environment: EnvironmentTier
    version: str
    edition: str
    health: ServerHealth
    cpu_percent: float
    memory_percent: float
    disk_free_gb: float
    disk_total_gb: float
    last_backup: Optional[datetime]
    is_source_eligible: bool
    is_target_eligible: bool
    databases: List[str]
    tags: Dict[str, str] = Field(default_factory=dict)


class SpaceAlert(BaseModel):
    alert_id: str
    server_name: str
    drive: str
    severity: AlertSeverity
    free_gb: float
    total_gb: float
    used_percent: float
    threshold_percent: float
    created_at: datetime
    acknowledged: bool
    message: str


class JobLog(BaseModel):
    timestamp: datetime
    level: Literal["INFO", "WARN", "ERROR", "DEBUG"]
    message: str
    source: str = "Agent"


class RestoreJob(BaseModel):
    job_id: str
    restore_request: RestoreRequest
    status: JobStatus
    created_at: datetime
    updated_at: datetime
    approved_at: Optional[datetime] = None
    approver: Optional[str] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    duration_seconds: Optional[int] = None
    powershell_pid: Optional[int] = None
    error_message: Optional[str] = None
    risk_score: int = Field(ge=0, le=100)
    governance_flags: List[str] = Field(default_factory=list)
    logs: List[JobLog] = Field(default_factory=list)
    progress_percent: int = Field(default=0, ge=0, le=100)


class AuditEntry(BaseModel):
    audit_id: str
    job_id: str
    action: str
    actor: str
    timestamp: datetime
    details: Dict[str, Any]
    ip_address: Optional[str] = None
    result: Literal["Success", "Failure", "Pending"]


class DashboardStats(BaseModel):
    total_restores: int
    success_rate: float
    avg_duration_minutes: float
    active_alerts: int
    pending_approvals: int
    running_jobs: int
    servers_healthy: int
    servers_total: int


class AgentAnalysisResult(BaseModel):
    query: str
    intent: str
    risk_score: int
    governance_passed: bool
    governance_flags: List[str]
    recommended_action: str
    reasoning: str
    suggested_workflow: Optional[str] = None
    warnings: List[str] = Field(default_factory=list)
