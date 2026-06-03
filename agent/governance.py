"""
Governance validation engine for RaaS Framework.
Implements rule-based scoring and policy checks before restore execution.
"""
from datetime import datetime, time
from typing import List, Tuple, Dict, Any
from models import RestoreRequest, EnvironmentTier, RestoreType


# ─── Constants ────────────────────────────────────────────────────────────────

# Business hours window (24h format, UTC)
BUSINESS_HOURS_START = time(7, 0)
BUSINESS_HOURS_END = time(18, 0)

# Approved requestor domains
APPROVED_DOMAINS = {"company.com", "corp.internal", "dba-team.local"}

# Approved requestors (whitelist for demo)
APPROVED_REQUESTORS = {
    "dba@company.com",
    "admin@company.com",
    "restore-svc@company.com",
    "john.smith@company.com",
    "jane.doe@company.com",
    "ops-team@company.com",
    "dba.team@corp.internal",
}

# Environments that require explicit approval regardless of other factors
ALWAYS_REQUIRE_APPROVAL = {EnvironmentTier.PRODUCTION, EnvironmentTier.STAGING}

# Maximum database size (GB) before mandatory approval
AUTO_APPROVE_MAX_DB_SIZE_GB = 50.0

# Environments where production source is allowed as a restore source
PROD_SOURCE_ALLOWED_TARGETS = {EnvironmentTier.STAGING, EnvironmentTier.UAT}

# Risk score thresholds
RISK_LOW = 30
RISK_MEDIUM = 60
RISK_HIGH = 80

# Risk score weights
RISK_WEIGHTS: Dict[str, int] = {
    "prod_target": 40,          # Restoring TO production
    "prod_source_to_prod": 50,  # Prod source → prod target
    "outside_business_hours": 10,
    "overwrite_existing": 15,
    "unapproved_requestor": 20,
    "no_justification": 25,
    "full_restore": 5,
    "immediate_schedule": 5,
    "large_db_estimate": 10,
}


# ─── Governance Engine ────────────────────────────────────────────────────────

class GovernanceEngine:
    """
    Evaluates restore requests against governance policies.
    Returns a risk score (0-100) and a list of policy flags.
    """

    def validate(
        self,
        request: RestoreRequest,
        source_env: EnvironmentTier,
        target_env: EnvironmentTier,
        estimated_db_size_gb: float = 0.0,
        current_time: datetime = None,
    ) -> Tuple[int, List[str], bool, str]:
        """
        Validate a restore request.

        Returns:
            Tuple of (risk_score, flags, governance_passed, reasoning)
        """
        if current_time is None:
            current_time = datetime.utcnow()

        flags: List[str] = []
        risk_score = 0
        reasoning_parts: List[str] = []

        # ── Rule 1: Production target check ──────────────────────────────────
        if target_env == EnvironmentTier.PRODUCTION:
            risk_score += RISK_WEIGHTS["prod_target"]
            flags.append("TARGET_IS_PRODUCTION")
            reasoning_parts.append(
                "Restoring to a PRODUCTION environment carries the highest risk — "
                "data loss and service disruption are possible."
            )

        # ── Rule 2: Prod-to-prod cross restore ────────────────────────────────
        if source_env == EnvironmentTier.PRODUCTION and target_env == EnvironmentTier.PRODUCTION:
            risk_score += RISK_WEIGHTS["prod_source_to_prod"]
            flags.append("PROD_TO_PROD_RESTORE")
            reasoning_parts.append(
                "Production-to-production restore is extremely high risk and requires "
                "CAB approval."
            )

        # ── Rule 3: Business hours check ─────────────────────────────────────
        current_local_time = current_time.time()
        if not (BUSINESS_HOURS_START <= current_local_time <= BUSINESS_HOURS_END):
            if target_env in ALWAYS_REQUIRE_APPROVAL:
                risk_score += RISK_WEIGHTS["outside_business_hours"]
                flags.append("OUTSIDE_BUSINESS_HOURS")
                reasoning_parts.append(
                    "Request submitted outside business hours (07:00–18:00 UTC) for a "
                    "sensitive environment."
                )

        # ── Rule 4: Requestor whitelist ───────────────────────────────────────
        requestor_domain = request.requestor.split("@")[-1] if "@" in request.requestor else ""
        if request.requestor not in APPROVED_REQUESTORS and requestor_domain not in APPROVED_DOMAINS:
            risk_score += RISK_WEIGHTS["unapproved_requestor"]
            flags.append("UNAPPROVED_REQUESTOR")
            reasoning_parts.append(
                f"Requestor '{request.requestor}' is not on the approved whitelist or "
                "known domain."
            )

        # ── Rule 5: Justification quality check ───────────────────────────────
        justification = request.justification.strip()
        if len(justification) < 30:
            risk_score += RISK_WEIGHTS["no_justification"]
            flags.append("INSUFFICIENT_JUSTIFICATION")
            reasoning_parts.append(
                "Business justification is too short or lacks sufficient detail."
            )

        # ── Rule 6: Overwrite existing database ───────────────────────────────
        if request.overwrite_existing:
            risk_score += RISK_WEIGHTS["overwrite_existing"]
            flags.append("OVERWRITE_EXISTING_DB")
            reasoning_parts.append(
                "Request will overwrite an existing database — existing data will be lost."
            )

        # ── Rule 7: Restore type risk ─────────────────────────────────────────
        if request.restore_type == RestoreType.FULL:
            risk_score += RISK_WEIGHTS["full_restore"]
            reasoning_parts.append("Full restore selected — longest downtime window.")

        # ── Rule 8: Immediate schedule risk ───────────────────────────────────
        if request.schedule_type.value == "Immediate" and target_env in ALWAYS_REQUIRE_APPROVAL:
            risk_score += RISK_WEIGHTS["immediate_schedule"]
            flags.append("IMMEDIATE_PRODUCTION_RESTORE")
            reasoning_parts.append(
                "Immediate execution requested for a sensitive environment without "
                "a maintenance window."
            )

        # ── Rule 9: Large database estimate ───────────────────────────────────
        if estimated_db_size_gb > AUTO_APPROVE_MAX_DB_SIZE_GB:
            risk_score += RISK_WEIGHTS["large_db_estimate"]
            flags.append("LARGE_DATABASE")
            reasoning_parts.append(
                f"Estimated database size ({estimated_db_size_gb:.1f} GB) exceeds the "
                f"auto-approve threshold of {AUTO_APPROVE_MAX_DB_SIZE_GB} GB."
            )

        # ── Rule 10: Governance acknowledgement ───────────────────────────────
        if not request.governance_acknowledged:
            flags.append("GOVERNANCE_NOT_ACKNOWLEDGED")
            reasoning_parts.append(
                "Requestor has not acknowledged the governance checklist."
            )

        # ── Determine if governance passes ────────────────────────────────────
        # Cap risk score at 100
        risk_score = min(risk_score, 100)

        # Hard blocks — regardless of score
        hard_blocks = {"TARGET_IS_PRODUCTION", "PROD_TO_PROD_RESTORE", "UNAPPROVED_REQUESTOR"}
        has_hard_block = any(f in flags for f in hard_blocks)

        # Auto-approve only for low-risk, non-production targets
        governance_passed = (
            risk_score <= RISK_LOW
            and not has_hard_block
            and target_env not in ALWAYS_REQUIRE_APPROVAL
        )

        reasoning = " | ".join(reasoning_parts) if reasoning_parts else "No governance issues detected."

        return risk_score, flags, governance_passed, reasoning

    def get_required_approvers(
        self, risk_score: int, target_env: EnvironmentTier, flags: List[str]
    ) -> List[str]:
        """Return list of required approver roles based on risk level."""
        approvers = []

        if target_env == EnvironmentTier.PRODUCTION:
            approvers.extend(["DBA Lead", "Change Advisory Board (CAB)"])
        elif target_env == EnvironmentTier.STAGING:
            approvers.append("DBA Lead")

        if risk_score >= RISK_HIGH:
            if "IT Director" not in approvers:
                approvers.append("IT Director")

        if "PROD_TO_PROD_RESTORE" in flags:
            approvers.extend(["CTO", "Change Advisory Board (CAB)"])

        return list(dict.fromkeys(approvers))  # deduplicate, preserve order

    def get_risk_label(self, risk_score: int) -> str:
        if risk_score <= RISK_LOW:
            return "Low"
        elif risk_score <= RISK_MEDIUM:
            return "Medium"
        elif risk_score <= RISK_HIGH:
            return "High"
        else:
            return "Critical"

    def analyze_natural_language_request(self, query: str) -> Dict[str, Any]:
        """
        Simple rule-based NL intent parser for the agent endpoint.
        Identifies the intent and relevant parameters from free-text queries.
        """
        query_lower = query.lower()
        intent = "unknown"
        suggested_workflow = None
        warnings = []

        # Intent classification via keyword matching
        if any(kw in query_lower for kw in ["restore", "recovery", "recover", "restoring"]):
            intent = "restore_request"
            suggested_workflow = "Invoke-SqlRestore.ps1"

        elif any(kw in query_lower for kw in ["status", "health", "check", "monitor", "ping"]):
            intent = "health_check"
            suggested_workflow = "Get-ServerStatus.ps1"

        elif any(kw in query_lower for kw in ["space", "disk", "storage", "alert", "full"]):
            intent = "space_alert_triage"
            suggested_workflow = "Get-SpaceAlerts.ps1"

        elif any(kw in query_lower for kw in ["approve", "approval", "authorize"]):
            intent = "approval_action"
            suggested_workflow = None

        elif any(kw in query_lower for kw in ["log", "audit", "history", "track"]):
            intent = "audit_query"
            suggested_workflow = "sp_GetRestoreAuditLog.sql"

        elif any(kw in query_lower for kw in ["validate", "check request", "governance"]):
            intent = "governance_check"
            suggested_workflow = "Validate-RestoreRequest.ps1"

        # Detect risky keywords
        if "production" in query_lower or "prod" in query_lower:
            warnings.append("Query references a production environment — elevated risk.")

        if "overwrite" in query_lower or "replace" in query_lower:
            warnings.append("Overwrite/replace detected — existing data may be lost.")

        if "immediately" in query_lower or "now" in query_lower or "urgent" in query_lower:
            warnings.append("Immediate execution requested — ensure change window is open.")

        if "all databases" in query_lower or "all dbs" in query_lower:
            warnings.append("Bulk operation detected — single-database scope is recommended.")

        return {
            "intent": intent,
            "suggested_workflow": suggested_workflow,
            "warnings": warnings,
        }


# Singleton instance
governance_engine = GovernanceEngine()
