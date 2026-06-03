"""
RaaS Framework - Main FastAPI Application & LLM Agent Orchestration Layer
=========================================================================
Serves as the brain of the SQL Restore-as-a-Service platform.
Orchestrates restore workflows, enforces governance, exposes REST + WebSocket APIs.
"""
import asyncio
import uuid
import random
import sys
import os
from datetime import datetime, timedelta
from typing import List, Optional, Dict, Any

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# Add current directory to path for local module imports
sys.path.insert(0, os.path.dirname(__file__))

from models import (
    RestoreRequest, RestoreJob, ServerInfo, SpaceAlert, AuditEntry,
    ApprovalRequest, AgentAnalyzeRequest, AgentAnalysisResult,
    DashboardStats, JobStatus, JobLog, EnvironmentTier, ServerHealth
)
from governance import governance_engine
from mock_data import SERVERS, SPACE_ALERTS, RESTORE_JOBS, AUDIT_LOG


# ─── App Initialization ───────────────────────────────────────────────────────

app = FastAPI(
    title="RaaS Framework API",
    description="SQL Restore-as-a-Service orchestration layer with AI-assisted governance",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict to UI origin
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── In-memory State ──────────────────────────────────────────────────────────
# In production these would be backed by a database

servers: Dict[str, ServerInfo] = dict(SERVERS)
space_alerts: List[SpaceAlert] = list(SPACE_ALERTS)
restore_jobs: Dict[str, RestoreJob] = dict(RESTORE_JOBS)
audit_log: List[AuditEntry] = list(AUDIT_LOG)

# Connected WebSocket clients per job
ws_clients: Dict[str, List[WebSocket]] = {}


# ─── Utility Helpers ──────────────────────────────────────────────────────────

def _new_job_id() -> str:
    return f"JOB-{str(uuid.uuid4())[:8].upper()}"


def _now() -> datetime:
    return datetime.utcnow()


def _log_entry(level: str, message: str, source: str = "Agent") -> JobLog:
    return JobLog(timestamp=_now(), level=level, message=message, source=source)


def _audit(job_id: str, action: str, actor: str, details: Dict[str, Any],
           result: str = "Success", ip: str = None) -> None:
    audit_log.append(AuditEntry(
        audit_id=str(uuid.uuid4()),
        job_id=job_id,
        action=action,
        actor=actor,
        timestamp=_now(),
        details=details,
        ip_address=ip,
        result=result,
    ))


def _get_server_env(server_name: str) -> EnvironmentTier:
    """Look up environment tier for a server name."""
    srv = servers.get(server_name)
    return srv.environment if srv else EnvironmentTier.DEV


def _estimate_db_size(server_name: str, db_name: str) -> float:
    """Rough size estimate based on mock data."""
    size_map = {
        "OrdersDB": 18.4, "CustomerDB": 12.1, "InventoryDB": 8.7,
        "FinanceDB": 45.2, "HRDB": 6.3, "ReportingDB": 35.2,
        "AnalyticsDB": 220.0, "DataWarehouseDB": 180.0,
    }
    return size_map.get(db_name, 10.0)


async def _broadcast_job_update(job_id: str, message: Dict[str, Any]) -> None:
    """Send a job update to all WebSocket subscribers."""
    dead = []
    for ws in ws_clients.get(job_id, []):
        try:
            await ws.send_json(message)
        except Exception:
            dead.append(ws)
    for ws in dead:
        ws_clients.get(job_id, []).remove(ws)


async def _simulate_restore_execution(job_id: str) -> None:
    """
    Simulate the async execution of a PowerShell restore workflow.
    Streams progress updates via WebSocket and polling.
    """
    job = restore_jobs.get(job_id)
    if not job:
        return

    job.status = JobStatus.RUNNING
    job.started_at = _now()
    job.updated_at = _now()

    db_size = _estimate_db_size(
        job.restore_request.source_server,
        job.restore_request.database_name
    )

    async def push_log(level: str, msg: str, source: str = "PowerShell"):
        entry = _log_entry(level, msg, source)
        job.logs.append(entry)
        job.updated_at = _now()
        await _broadcast_job_update(job_id, {
            "event": "log",
            "job_id": job_id,
            "log": {"timestamp": entry.timestamp.isoformat(), "level": level,
                    "message": msg, "source": source}
        })

    async def push_progress(pct: int):
        job.progress_percent = pct
        job.updated_at = _now()
        await _broadcast_job_update(job_id, {
            "event": "progress",
            "job_id": job_id,
            "progress": pct,
            "status": job.status.value,
        })

    try:
        await push_log("INFO", f"Launching Invoke-SqlRestore.ps1 on {job.restore_request.target_server}", "Agent")
        await asyncio.sleep(0.5)

        await push_log("INFO", "Connecting to source server to enumerate backup chain...", "PowerShell")
        await asyncio.sleep(0.8)

        await push_log(
            "INFO",
            f"Backup chain identified: Full backup {db_size:.1f} GB at {(_now() - timedelta(hours=2)).strftime('%Y-%m-%d %H:%M')} UTC",
            "PowerShell"
        )
        await push_progress(5)
        await asyncio.sleep(0.5)

        target = servers.get(job.restore_request.target_server)
        if target and target.disk_free_gb < db_size * 1.2:
            await push_log(
                "ERROR",
                f"Pre-flight FAILED: Target disk free {target.disk_free_gb:.1f} GB < required {db_size * 1.2:.1f} GB",
                "PowerShell"
            )
            raise RuntimeError(
                f"Insufficient disk space on target. Required {db_size * 1.2:.1f} GB, available {target.disk_free_gb:.1f} GB"
            )

        await push_log("INFO", "Pre-flight checks passed. Beginning RESTORE DATABASE operation.", "PowerShell")
        await push_progress(10)

        for pct in range(15, 101, 5):
            await asyncio.sleep(0.3)
            if pct % 25 == 0:
                await push_log("INFO", f"RESTORE DATABASE [{job.restore_request.database_name}] progress: {pct}%", "PowerShell")
            await push_progress(pct)

        await asyncio.sleep(0.4)
        await push_log("INFO", "Running post-restore validation: DBCC CHECKDB...", "PowerShell")
        await asyncio.sleep(0.5)
        await push_log("INFO", "DBCC CHECKDB completed with 0 errors.", "PowerShell")

        duration = int((_now() - job.started_at).total_seconds())
        await push_log("INFO", f"Restore completed successfully. Duration: {duration // 60}m {duration % 60}s", "Agent")

        job.status = JobStatus.COMPLETED
        job.completed_at = _now()
        job.duration_seconds = duration
        job.progress_percent = 100
        job.updated_at = _now()

        _audit(job_id, "RESTORE_COMPLETED", "System",
               {"duration_seconds": duration, "dbcc_check": "PASSED"})

        await _broadcast_job_update(job_id, {
            "event": "completed",
            "job_id": job_id,
            "status": "Completed",
            "duration_seconds": duration,
        })

    except Exception as exc:
        err_msg = str(exc)
        await push_log("ERROR", f"Restore FAILED: {err_msg}", "PowerShell")
        await push_log("ERROR", "Initiating cleanup on target server.", "PowerShell")

        job.status = JobStatus.FAILED
        job.completed_at = _now()
        job.error_message = err_msg
        job.progress_percent = 0
        job.updated_at = _now()

        _audit(job_id, "RESTORE_FAILED", "System", {"error": err_msg}, result="Failure")

        await _broadcast_job_update(job_id, {
            "event": "failed",
            "job_id": job_id,
            "status": "Failed",
            "error": err_msg,
        })


# ─── Background server metric simulation ──────────────────────────────────────

async def _jitter_server_metrics():
    """Periodically nudge server metrics to simulate live data."""
    while True:
        await asyncio.sleep(30)
        for srv in servers.values():
            srv.cpu_percent = min(99.9, max(1.0, srv.cpu_percent + random.uniform(-5, 5)))
            srv.memory_percent = min(99.9, max(10.0, srv.memory_percent + random.uniform(-2, 2)))


@app.on_event("startup")
async def startup_event():
    asyncio.create_task(_jitter_server_metrics())


# ═══════════════════════════════════════════════════════════════════════════════
# REST ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Health ───────────────────────────────────────────────────────────────────

@app.get("/health", tags=["System"])
async def health_check():
    """Returns service health status."""
    return {
        "status": "healthy",
        "service": "RaaS Agent",
        "version": "1.0.0",
        "timestamp": _now().isoformat(),
        "servers_monitored": len(servers),
        "active_jobs": sum(1 for j in restore_jobs.values() if j.status in (JobStatus.RUNNING, JobStatus.APPROVED)),
    }


# ─── Servers ──────────────────────────────────────────────────────────────────

@app.get("/servers", response_model=List[ServerInfo], tags=["Inventory"])
async def get_servers(
    environment: Optional[EnvironmentTier] = Query(None),
    health: Optional[ServerHealth] = Query(None),
    source_eligible: Optional[bool] = Query(None),
    target_eligible: Optional[bool] = Query(None),
):
    """Return the list of monitored SQL Server instances with optional filters."""
    result = list(servers.values())

    if environment:
        result = [s for s in result if s.environment == environment]
    if health:
        result = [s for s in result if s.health == health]
    if source_eligible is not None:
        result = [s for s in result if s.is_source_eligible == source_eligible]
    if target_eligible is not None:
        result = [s for s in result if s.is_target_eligible == target_eligible]

    return result


@app.get("/servers/{server_name}", response_model=ServerInfo, tags=["Inventory"])
async def get_server(server_name: str):
    """Return details for a single server."""
    srv = servers.get(server_name)
    if not srv:
        raise HTTPException(status_code=404, detail=f"Server '{server_name}' not found")
    return srv


# ─── Alerts ───────────────────────────────────────────────────────────────────

@app.get("/alerts", response_model=List[SpaceAlert], tags=["Monitoring"])
async def get_alerts(
    severity: Optional[str] = Query(None),
    acknowledged: Optional[bool] = Query(None),
):
    """Return space alerts with optional severity/acknowledgement filters."""
    result = list(space_alerts)
    if severity:
        result = [a for a in result if a.severity.value.lower() == severity.lower()]
    if acknowledged is not None:
        result = [a for a in result if a.acknowledged == acknowledged]
    return result


@app.post("/alerts/{alert_id}/acknowledge", tags=["Monitoring"])
async def acknowledge_alert(alert_id: str, actor: str = Query("user@company.com")):
    """Acknowledge a space alert."""
    for alert in space_alerts:
        if alert.alert_id == alert_id:
            alert.acknowledged = True
            _audit("SYSTEM", "ALERT_ACKNOWLEDGED", actor, {"alert_id": alert_id, "server": alert.server_name})
            return {"status": "acknowledged", "alert_id": alert_id}
    raise HTTPException(status_code=404, detail="Alert not found")


# ─── Jobs ─────────────────────────────────────────────────────────────────────

@app.get("/jobs", response_model=List[RestoreJob], tags=["Jobs"])
async def get_jobs(
    status: Optional[JobStatus] = Query(None),
    limit: int = Query(50, le=200),
):
    """Return restore jobs, optionally filtered by status."""
    result = sorted(restore_jobs.values(), key=lambda j: j.created_at, reverse=True)
    if status:
        result = [j for j in result if j.status == status]
    return result[:limit]


@app.get("/jobs/{job_id}", response_model=RestoreJob, tags=["Jobs"])
async def get_job(job_id: str):
    """Return full details for a specific restore job."""
    job = restore_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found")
    return job


# ─── Dashboard ────────────────────────────────────────────────────────────────

@app.get("/dashboard", response_model=DashboardStats, tags=["Dashboard"])
async def get_dashboard():
    """Return aggregated KPI statistics for the dashboard."""
    jobs = list(restore_jobs.values())
    completed = [j for j in jobs if j.status == JobStatus.COMPLETED]
    failed = [j for j in jobs if j.status == JobStatus.FAILED]
    total_terminal = len(completed) + len(failed)
    success_rate = (len(completed) / total_terminal * 100) if total_terminal > 0 else 0.0

    durations = [j.duration_seconds for j in completed if j.duration_seconds]
    avg_duration = (sum(durations) / len(durations) / 60) if durations else 0.0

    return DashboardStats(
        total_restores=len(jobs),
        success_rate=round(success_rate, 1),
        avg_duration_minutes=round(avg_duration, 1),
        active_alerts=sum(1 for a in space_alerts if not a.acknowledged),
        pending_approvals=sum(1 for j in jobs if j.status == JobStatus.AWAITING_APPROVAL),
        running_jobs=sum(1 for j in jobs if j.status == JobStatus.RUNNING),
        servers_healthy=sum(1 for s in servers.values() if s.health == ServerHealth.HEALTHY),
        servers_total=len(servers),
    )


# ─── Restore Request Lifecycle ────────────────────────────────────────────────

@app.post("/restore/request", response_model=RestoreJob, status_code=201, tags=["Restore"])
async def create_restore_request(request: RestoreRequest, req: Request = None):
    """
    Submit a new restore request.
    The governance engine scores the request and determines whether
    it can be auto-approved or requires manual approval.
    """
    # Validate servers exist
    if request.source_server not in servers:
        raise HTTPException(status_code=400, detail=f"Source server '{request.source_server}' not found in inventory")
    if request.target_server not in servers:
        raise HTTPException(status_code=400, detail=f"Target server '{request.target_server}' not found in inventory")

    source_srv = servers[request.source_server]
    target_srv = servers[request.target_server]

    if not source_srv.is_source_eligible:
        raise HTTPException(status_code=400, detail=f"Server '{request.source_server}' is not eligible as a restore source")
    if not target_srv.is_target_eligible:
        raise HTTPException(status_code=400, detail=f"Server '{request.target_server}' is not eligible as a restore target")

    # Run governance validation
    db_size = _estimate_db_size(request.source_server, request.database_name)
    risk_score, flags, gov_passed, reasoning = governance_engine.validate(
        request=request,
        source_env=source_srv.environment,
        target_env=target_srv.environment,
        estimated_db_size_gb=db_size,
    )

    # Determine initial status
    if gov_passed:
        initial_status = JobStatus.APPROVED
    else:
        initial_status = JobStatus.AWAITING_APPROVAL

    job_id = _new_job_id()
    now = _now()

    logs = [
        _log_entry("INFO", "Restore request received and validated by governance engine.", "Governance"),
        _log_entry("INFO", f"Risk score: {risk_score} ({governance_engine.get_risk_label(risk_score)}). Flags: {flags or 'None'}.", "Governance"),
    ]

    if gov_passed:
        logs.append(_log_entry("INFO", "Auto-approved: risk score within threshold for non-sensitive target.", "Governance"))
    else:
        required = governance_engine.get_required_approvers(risk_score, target_srv.environment, flags)
        logs.append(_log_entry("WARN", f"Manual approval required from: {', '.join(required)}. Reason: {reasoning}", "Governance"))

    job = RestoreJob(
        job_id=job_id,
        restore_request=request,
        status=initial_status,
        created_at=now,
        updated_at=now,
        approved_at=now if gov_passed else None,
        approver="System (Auto)" if gov_passed else None,
        risk_score=risk_score,
        governance_flags=flags,
        logs=logs,
        progress_percent=0,
    )

    restore_jobs[job_id] = job

    client_ip = req.client.host if req else None
    _audit(job_id, "RESTORE_REQUEST_CREATED", request.requestor, {
        "source": request.source_server,
        "target": request.target_server,
        "database": request.database_name,
        "risk_score": risk_score,
        "auto_approved": gov_passed,
    }, ip=client_ip)

    return job


@app.post("/restore/approve/{job_id}", response_model=RestoreJob, tags=["Restore"])
async def approve_restore(job_id: str, approval: ApprovalRequest, req: Request = None):
    """
    Approve or reject a pending restore request.
    """
    job = restore_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found")

    if job.status not in (JobStatus.AWAITING_APPROVAL, JobStatus.PENDING):
        raise HTTPException(
            status_code=409,
            detail=f"Job is in '{job.status.value}' state — only AWAITING_APPROVAL jobs can be acted upon"
        )

    now = _now()
    client_ip = req.client.host if req else None

    if approval.approved:
        job.status = JobStatus.APPROVED
        job.approved_at = now
        job.approver = approval.approver
        job.updated_at = now
        job.logs.append(_log_entry("INFO", f"Restore APPROVED by {approval.approver}. Notes: {approval.notes or 'N/A'}", "Approval"))
        _audit(job_id, "RESTORE_APPROVED", approval.approver,
               {"notes": approval.notes}, ip=client_ip)
    else:
        job.status = JobStatus.REJECTED
        job.updated_at = now
        job.logs.append(_log_entry("WARN", f"Restore REJECTED by {approval.approver}. Reason: {approval.notes or 'No reason provided'}", "Approval"))
        _audit(job_id, "RESTORE_REJECTED", approval.approver,
               {"notes": approval.notes}, result="Failure", ip=client_ip)

    return job


@app.post("/restore/execute/{job_id}", response_model=RestoreJob, tags=["Restore"])
async def execute_restore(job_id: str, req: Request = None):
    """
    Trigger execution of an approved restore job.
    Spawns an async simulation of the PowerShell orchestrator.
    """
    job = restore_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found")

    if job.status != JobStatus.APPROVED:
        raise HTTPException(
            status_code=409,
            detail=f"Job must be in APPROVED state to execute. Current state: {job.status.value}"
        )

    job.logs.append(_log_entry("INFO", "Execution triggered by operator.", "Agent"))
    _audit(job_id, "RESTORE_EXECUTION_TRIGGERED", "operator",
           {"job_id": job_id}, ip=req.client.host if req else None)

    asyncio.create_task(_simulate_restore_execution(job_id))

    return job


@app.get("/restore/status/{job_id}", tags=["Restore"])
async def get_restore_status(job_id: str):
    """Return lightweight status summary for polling."""
    job = restore_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found")

    return {
        "job_id": job.job_id,
        "status": job.status.value,
        "progress_percent": job.progress_percent,
        "updated_at": job.updated_at.isoformat(),
        "error_message": job.error_message,
        "logs_count": len(job.logs),
    }


# ─── Agent Analysis ───────────────────────────────────────────────────────────

@app.post("/agent/analyze", response_model=AgentAnalysisResult, tags=["Agent"])
async def agent_analyze(body: AgentAnalyzeRequest):
    """
    AI agent endpoint: accepts a natural language query or restore request description
    and returns structured analysis including intent, risk score, governance flags,
    and recommended action.
    """
    query = body.query.strip()
    context = body.context or {}

    # Parse intent via rule-based NL analysis
    nl_result = governance_engine.analyze_natural_language_request(query)
    intent = nl_result["intent"]
    suggested_workflow = nl_result["suggested_workflow"]
    warnings: List[str] = nl_result["warnings"]

    # If we have a structured restore context, run full governance check
    risk_score = 0
    gov_flags: List[str] = []
    gov_passed = True
    reasoning = "Rule-based analysis completed."

    if intent == "restore_request" and context.get("source_server") and context.get("target_server"):
        source_env = _get_server_env(context["source_server"])
        target_env = _get_server_env(context["target_server"])
        db_size = _estimate_db_size(context.get("source_server", ""), context.get("database_name", ""))

        try:
            mock_req = RestoreRequest(
                source_server=context.get("source_server", "SQL-DEV-01"),
                target_server=context.get("target_server", "SQL-DEV-01"),
                database_name=context.get("database_name", "TestDB"),
                justification=context.get("justification", query),
                requestor=context.get("requestor", "analyst@company.com"),
                restore_type=context.get("restore_type", "Full"),
                schedule_type=context.get("schedule_type", "Immediate"),
                governance_acknowledged=context.get("governance_acknowledged", False),
            )
            risk_score, gov_flags, gov_passed, reasoning = governance_engine.validate(
                mock_req, source_env, target_env, db_size
            )
        except Exception as e:
            reasoning = f"Partial context provided — could not run full governance check: {e}"

    elif intent == "space_alert_triage":
        # Summarize current space alerts
        critical = [a for a in space_alerts if a.severity.value == "Critical" and not a.acknowledged]
        warnings_list = [a for a in space_alerts if a.severity.value == "Warning" and not a.acknowledged]
        reasoning = (
            f"Space alert triage: {len(critical)} CRITICAL, {len(warnings_list)} WARNING alerts active. "
            + (f"Critical: {', '.join(a.server_name for a in critical)}." if critical else "No critical alerts.")
        )
        risk_score = min(100, len(critical) * 30 + len(warnings_list) * 10)

    elif intent == "health_check":
        degraded = [s for s in servers.values() if s.health.value in ("Degraded", "Critical", "Offline")]
        reasoning = (
            f"Health check summary: {len(servers) - len(degraded)}/{len(servers)} servers healthy. "
            + (f"Issues: {', '.join(s.server_name for s in degraded)}." if degraded else "All servers nominal.")
        )

    # Determine recommended action
    if not gov_passed or risk_score > 60:
        recommended_action = "ESCALATE_TO_APPROVAL — Submit request for manual DBA/CAB review."
    elif intent == "restore_request":
        recommended_action = "PROCEED — Risk is within acceptable threshold. Execute Invoke-SqlRestore.ps1."
    elif intent == "space_alert_triage":
        recommended_action = "INVESTIGATE — Review disk usage on flagged servers and expand or archive."
    elif intent == "health_check":
        recommended_action = "MONITOR — Review degraded servers; escalate if health worsens."
    else:
        recommended_action = "REVIEW — Clarify request scope and resubmit with structured parameters."

    return AgentAnalysisResult(
        query=query,
        intent=intent,
        risk_score=risk_score,
        governance_passed=gov_passed,
        governance_flags=gov_flags,
        recommended_action=recommended_action,
        reasoning=reasoning,
        suggested_workflow=suggested_workflow,
        warnings=warnings,
    )


# ─── Audit Log ────────────────────────────────────────────────────────────────

@app.get("/audit/logs", response_model=List[AuditEntry], tags=["Audit"])
async def get_audit_logs(
    job_id: Optional[str] = Query(None),
    actor: Optional[str] = Query(None),
    action: Optional[str] = Query(None),
    limit: int = Query(100, le=500),
):
    """Return audit log entries with optional filters."""
    result = sorted(audit_log, key=lambda e: e.timestamp, reverse=True)

    if job_id:
        result = [e for e in result if e.job_id == job_id]
    if actor:
        result = [e for e in result if actor.lower() in e.actor.lower()]
    if action:
        result = [e for e in result if action.upper() in e.action.upper()]

    return result[:limit]


# ─── WebSocket — Live Job Updates ─────────────────────────────────────────────

@app.websocket("/ws/jobs/{job_id}")
async def websocket_job_updates(websocket: WebSocket, job_id: str):
    """
    WebSocket endpoint for real-time job log streaming.
    Clients receive log entries, progress updates, and completion events.
    """
    await websocket.accept()

    if job_id not in ws_clients:
        ws_clients[job_id] = []
    ws_clients[job_id].append(websocket)

    # Send current state immediately on connect
    job = restore_jobs.get(job_id)
    if job:
        await websocket.send_json({
            "event": "current_state",
            "job_id": job_id,
            "status": job.status.value,
            "progress": job.progress_percent,
            "logs": [
                {"timestamp": log.timestamp.isoformat(), "level": log.level,
                 "message": log.message, "source": log.source}
                for log in job.logs[-50:]  # send last 50 logs
            ],
        })

    try:
        while True:
            # Keep connection alive with heartbeat
            await asyncio.sleep(15)
            await websocket.send_json({"event": "heartbeat", "timestamp": _now().isoformat()})
    except WebSocketDisconnect:
        pass
    finally:
        if job_id in ws_clients:
            try:
                ws_clients[job_id].remove(websocket)
            except ValueError:
                pass


# ─── Entry Point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("raas_agent:app", host="0.0.0.0", port=8080, reload=True, log_level="info")
