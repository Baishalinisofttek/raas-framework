/*
================================================================================
  RaaS Framework — Frontend Application (app.js)
  Vanilla JS SPA: no framework dependencies.
================================================================================
*/

const APP_CONFIG = {
    apiUrl: localStorage.getItem('raas_api_url') || 'http://localhost:8080',
    pollInterval: parseInt(localStorage.getItem('raas_poll_interval') || '5') * 1000,
    currentUser: localStorage.getItem('raas_user') || 'dba@company.com',
};

// ─── State ───────────────────────────────────────────────────────────────────

const state = {
    servers: [],
    alerts: [],
    jobs: [],
    auditLog: [],
    dashboard: null,
    currentJobId: null,
    pendingApprovalJobId: null,
    pollTimers: [],
};

// ─── API Helpers ─────────────────────────────────────────────────────────────

async function apiGet(path) {
    const res = await fetch(`${APP_CONFIG.apiUrl}${path}`);
    if (!res.ok) throw new Error(`GET ${path} → ${res.status}`);
    return res.json();
}

async function apiPost(path, body) {
    const res = await fetch(`${APP_CONFIG.apiUrl}${path}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
    if (!res.ok) {
        const err = await res.json().catch(() => ({ detail: res.statusText }));
        throw new Error(err.detail || res.statusText);
    }
    return res.json();
}

// ─── Routing / View Management ───────────────────────────────────────────────

const views = {
    'dashboard':   { title: 'Dashboard',     load: () => app.loadDashboard() },
    'new-restore': { title: 'New Restore',   load: () => app.loadNewRestoreForm() },
    'jobs':        { title: 'Restore Jobs',  load: () => app.loadJobs() },
    'alerts':      { title: 'Alerts',        load: () => app.loadAlerts() },
    'audit':       { title: 'Audit Log',     load: () => app.loadAuditLog() },
    'agent':       { title: 'AI Agent',      load: () => {} },
    'settings':    { title: 'Settings',      load: () => app.loadSettings() },
};

function navigate(viewId) {
    // Hide all views, deactivate nav links
    document.querySelectorAll('.view').forEach(v => v.classList.add('hidden'));
    document.querySelectorAll('.nav-link').forEach(a => a.classList.remove('active'));

    const view = document.getElementById(`view-${viewId}`);
    const link = document.querySelector(`[data-view="${viewId}"]`);
    if (!view) return;

    view.classList.remove('hidden');
    if (link) link.classList.add('active');
    document.getElementById('view-title').textContent = views[viewId]?.title || viewId;

    // Cancel any previous pollers
    state.pollTimers.forEach(clearInterval);
    state.pollTimers = [];

    views[viewId]?.load();
}

// ─── Formatting Helpers ──────────────────────────────────────────────────────

function fmtDate(iso) {
    if (!iso) return '—';
    return new Date(iso).toLocaleString('en-US', {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
    });
}

function fmtDuration(secs) {
    if (!secs) return '—';
    const m = Math.floor(secs / 60), s = secs % 60;
    return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

function statusBadge(status) {
    const cls = (status || '').toLowerCase().replace(/\s+/g, '');
    return `<span class="badge ${cls}">${status}</span>`;
}

function severityBadge(sev) {
    const cls = (sev || '').toLowerCase();
    return `<span class="badge ${cls}">${sev}</span>`;
}

function healthBadge(health) {
    const cls = (health || '').toLowerCase();
    return `<span class="badge ${cls}">${health}</span>`;
}

function riskColor(score) {
    if (score <= 30) return '#22c55e';
    if (score <= 60) return '#f59e0b';
    if (score <= 80) return '#ef4444';
    return '#dc2626';
}

function escHtml(str) {
    return String(str || '')
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ─── Notifications ────────────────────────────────────────────────────────────

function showFeedback(containerId, message, type = 'info') {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = `<div class="alert ${type}">${message}</div>`;
    if (type !== 'danger') {
        setTimeout(() => { el.innerHTML = ''; }, 6000);
    }
}

// ─── API Status Check ─────────────────────────────────────────────────────────

async function checkApiHealth() {
    const badge = document.getElementById('api-status');
    try {
        await apiGet('/health');
        badge.textContent = 'API Connected';
        badge.className = 'badge approved';
    } catch {
        badge.textContent = 'API Offline';
        badge.className = 'badge failed';
    }
}

// ─── Dashboard ────────────────────────────────────────────────────────────────

async function loadDashboard() {
    try {
        const [dash, servers, jobs, alerts] = await Promise.all([
            apiGet('/dashboard'),
            apiGet('/servers'),
            apiGet('/jobs?limit=10'),
            apiGet('/alerts'),
        ]);
        state.dashboard = dash;
        state.servers = servers;
        state.jobs = jobs;
        state.alerts = alerts;
        renderKpis(dash);
        renderServerGrid(servers);
        renderActiveJobs(jobs);
        renderRecentJobsTable(jobs);
        updateBadges(dash);
    } catch (err) {
        document.getElementById('server-grid').innerHTML =
            `<div class="alert danger">Failed to load dashboard: ${escHtml(err.message)}</div>`;
    }
}

function renderKpis(d) {
    document.getElementById('kpi-total').textContent = d.total_restores;
    document.getElementById('kpi-success').textContent = d.success_rate + '%';
    document.getElementById('kpi-duration').textContent = d.avg_duration_minutes + 'm';
    document.getElementById('kpi-alerts').textContent = d.active_alerts;
    document.getElementById('kpi-pending').textContent = d.pending_approvals;
    document.getElementById('kpi-health').textContent = `${d.servers_healthy}/${d.servers_total}`;
}

function updateBadges(d) {
    const pb = document.getElementById('pending-badge');
    const ab = document.getElementById('alert-badge');
    if (d.pending_approvals > 0) {
        pb.textContent = d.pending_approvals;
        pb.classList.remove('hidden');
    } else pb.classList.add('hidden');
    if (d.active_alerts > 0) {
        ab.textContent = d.active_alerts;
        ab.classList.remove('hidden');
    } else ab.classList.add('hidden');
}

function renderServerGrid(servers) {
    if (!servers.length) {
        document.getElementById('server-grid').innerHTML = '<div class="empty-state">No servers found.</div>';
        return;
    }
    const html = servers.map(s => {
        const diskPct = Math.round((1 - s.disk_free_gb / s.disk_total_gb) * 100);
        const diskColor = diskPct > 85 ? 'var(--danger)' : diskPct > 70 ? 'var(--warning)' : 'var(--teal)';
        return `
        <div class="server-card">
            <div class="server-card-header">
                <span class="server-name">${escHtml(s.server_name)}</span>
                ${healthBadge(s.health)}
            </div>
            <div class="server-meta">${escHtml(s.environment)} &nbsp;·&nbsp; ${escHtml(s.version)}</div>
            <div class="server-stats">
                <div class="stat-item"><div class="stat-label">CPU</div><div class="stat-val">${s.cpu_percent.toFixed(1)}%</div></div>
                <div class="stat-item"><div class="stat-label">Memory</div><div class="stat-val">${s.memory_percent.toFixed(1)}%</div></div>
                <div class="stat-item"><div class="stat-label">Disk Free</div><div class="stat-val">${s.disk_free_gb.toFixed(0)} GB</div></div>
            </div>
            <div class="progress-container" style="height:5px;margin-top:8px;">
                <div class="progress-bar" style="width:${diskPct}%;background:${diskColor};box-shadow:0 0 6px ${diskColor};"></div>
            </div>
            <div class="text-xs text-muted mt-1">${diskPct}% disk used</div>
        </div>`;
    }).join('');
    document.getElementById('server-grid').innerHTML = html;
}

function renderActiveJobs(jobs) {
    const active = jobs.filter(j => ['Running', 'Approved'].includes(j.status));
    const el = document.getElementById('active-jobs-list');
    if (!active.length) {
        el.innerHTML = '<div class="empty-state"><div class="icon">✅</div><p>No active jobs</p></div>';
        return;
    }
    el.innerHTML = active.map(j => `
        <div style="padding:12px;border:1px solid var(--border);border-radius:8px;margin-bottom:10px;cursor:pointer;"
             onclick="app.navigateAndOpenJob('${j.job_id}')">
            <div class="flex justify-between items-center">
                <strong>${escHtml(j.job_id)}</strong>
                ${statusBadge(j.status)}
            </div>
            <div class="text-sm text-muted">${escHtml(j.restore_request.database_name)}</div>
            ${j.status === 'Running' ? `
            <div class="progress-container" style="margin-top:8px;">
                <div class="progress-bar" style="width:${j.progress_percent}%"></div>
            </div>
            <div class="text-sm text-muted">${j.progress_percent}%</div>` : ''}
        </div>`).join('');
}

function renderRecentJobsTable(jobs) {
    if (!jobs.length) {
        document.getElementById('recent-jobs-table').innerHTML = '<div class="empty-state">No jobs found.</div>';
        return;
    }
    const rows = jobs.slice(0, 8).map(j => `
        <tr style="cursor:pointer;" onclick="app.navigateAndOpenJob('${j.job_id}')">
            <td><code>${escHtml(j.job_id)}</code></td>
            <td>${escHtml(j.restore_request.database_name)}</td>
            <td>${escHtml(j.restore_request.source_server)}</td>
            <td>${escHtml(j.restore_request.target_server)}</td>
            <td>${statusBadge(j.status)}</td>
            <td><span style="color:${riskColor(j.risk_score)};font-weight:600;">${j.risk_score}</span></td>
            <td>${fmtDate(j.created_at)}</td>
        </tr>`).join('');
    document.getElementById('recent-jobs-table').innerHTML = `
        <table>
            <thead><tr>
                <th>Job ID</th><th>Database</th><th>Source</th><th>Target</th>
                <th>Status</th><th>Risk</th><th>Created</th>
            </tr></thead>
            <tbody>${rows}</tbody>
        </table>`;
}

// ─── New Restore Form ─────────────────────────────────────────────────────────

async function loadNewRestoreForm() {
    try {
        const servers = await apiGet('/servers');
        state.servers = servers;
        populateServerDropdowns(servers);
    } catch (err) {
        showFeedback('restore-form-feedback', 'Failed to load server list: ' + escHtml(err.message), 'danger');
    }
}

function populateServerDropdowns(servers) {
    const sourceSel = document.getElementById('source-server');
    const targetSel = document.getElementById('target-server');
    const sources = servers.filter(s => s.is_source_eligible);
    const targets = servers.filter(s => s.is_target_eligible);

    sourceSel.innerHTML = '<option value="">Select source server...</option>' +
        sources.map(s => `<option value="${escHtml(s.server_name)}" data-env="${s.environment}">
            ${escHtml(s.server_name)} (${s.environment})</option>`).join('');

    targetSel.innerHTML = '<option value="">Select target server...</option>' +
        targets.map(s => `<option value="${escHtml(s.server_name)}" data-env="${s.environment}">
            ${escHtml(s.server_name)} (${s.environment})</option>`).join('');
}

function toggleScheduleTime() {
    const type = document.getElementById('schedule-type').value;
    const timeInput = document.getElementById('scheduled-time');
    timeInput.disabled = (type !== 'Scheduled');
    if (type === 'Scheduled') timeInput.focus();
}

async function submitRestoreForm(event) {
    event.preventDefault();
    const btn = document.getElementById('submit-restore-btn');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Submitting...';

    const allChecked = ['gov1','gov2','gov3','gov4','governance-ack'].every(
        id => document.getElementById(id).checked
    );
    if (!allChecked) {
        showFeedback('restore-form-feedback', 'Please complete the governance checklist before submitting.', 'warning');
        btn.disabled = false;
        btn.innerHTML = '🚀 Submit Restore Request';
        return;
    }

    const payload = {
        source_server:           document.getElementById('source-server').value,
        target_server:           document.getElementById('target-server').value,
        database_name:           document.getElementById('database-name').value,
        restore_type:            document.getElementById('restore-type').value,
        schedule_type:           document.getElementById('schedule-type').value,
        requestor:               document.getElementById('requestor').value,
        justification:           document.getElementById('justification').value,
        overwrite_existing:      document.getElementById('overwrite-existing').checked,
        governance_acknowledged: document.getElementById('governance-ack').checked,
    };

    const schedTime = document.getElementById('scheduled-time').value;
    if (schedTime) payload.scheduled_time = new Date(schedTime).toISOString();

    try {
        const job = await apiPost('/restore/request', payload);
        const msg = job.status === 'Approved'
            ? `✅ Request auto-approved! Job <strong>${escHtml(job.job_id)}</strong> is ready to execute.`
            : `⏳ Request submitted. Job <strong>${escHtml(job.job_id)}</strong> is awaiting approval (Risk: ${job.risk_score}).`;
        showFeedback('restore-form-feedback', msg, job.status === 'Approved' ? 'success' : 'warning');
        clearForm();
    } catch (err) {
        showFeedback('restore-form-feedback', 'Error: ' + escHtml(err.message), 'danger');
    } finally {
        btn.disabled = false;
        btn.innerHTML = '🚀 Submit Restore Request';
    }
}

function clearForm() {
    document.getElementById('restore-form').reset();
    document.getElementById('scheduled-time').disabled = true;
    document.getElementById('restore-form-feedback').innerHTML = '';
}

// ─── Jobs View ────────────────────────────────────────────────────────────────

async function loadJobs() {
    try {
        const jobs = await apiGet('/jobs?limit=100');
        state.jobs = jobs;
        renderJobsTable(jobs);
        // Poll for running jobs
        if (jobs.some(j => j.status === 'Running')) {
            const t = setInterval(async () => {
                const fresh = await apiGet('/jobs?limit=100');
                state.jobs = fresh;
                renderJobsTable(fresh);
                if (state.currentJobId) refreshJobDetail(state.currentJobId);
            }, APP_CONFIG.pollInterval);
            state.pollTimers.push(t);
        }
    } catch (err) {
        document.getElementById('jobs-table-container').innerHTML =
            `<div class="alert danger">Failed to load jobs: ${escHtml(err.message)}</div>`;
    }
}

function filterJobs() {
    const statusFilter = document.getElementById('jobs-filter').value;
    const filtered = statusFilter
        ? state.jobs.filter(j => j.status === statusFilter)
        : state.jobs;
    renderJobsTable(filtered);
}

function renderJobsTable(jobs) {
    if (!jobs.length) {
        document.getElementById('jobs-table-container').innerHTML =
            '<div class="empty-state"><div class="icon">📋</div><p>No jobs found.</p></div>';
        return;
    }
    const rows = jobs.map(j => `
        <tr style="cursor:pointer;" onclick="app.openJobDetail('${j.job_id}')">
            <td><code>${escHtml(j.job_id)}</code></td>
            <td>${escHtml(j.restore_request.database_name)}</td>
            <td>${escHtml(j.restore_request.source_server)} → ${escHtml(j.restore_request.target_server)}</td>
            <td>${escHtml(j.restore_request.restore_type)}</td>
            <td>${statusBadge(j.status)}</td>
            <td><span style="color:${riskColor(j.risk_score)};font-weight:600;">${j.risk_score}</span></td>
            <td>${j.status === 'Running' ? `<div class="progress-container" style="min-width:80px;height:6px;">
                <div class="progress-bar" style="width:${j.progress_percent}%"></div></div>` : fmtDuration(j.duration_seconds)}</td>
            <td>${fmtDate(j.created_at)}</td>
        </tr>`).join('');

    document.getElementById('jobs-table-container').innerHTML = `
        <table>
            <thead><tr>
                <th>Job ID</th><th>Database</th><th>Servers</th><th>Type</th>
                <th>Status</th><th>Risk</th><th>Duration</th><th>Created</th>
            </tr></thead>
            <tbody>${rows}</tbody>
        </table>`;
}

async function openJobDetail(jobId) {
    state.currentJobId = jobId;
    const panel = document.getElementById('job-detail-panel');
    panel.classList.remove('hidden');
    panel.scrollIntoView({ behavior: 'smooth' });
    await refreshJobDetail(jobId);

    // Auto-poll if running
    const job = state.jobs.find(j => j.job_id === jobId);
    if (job && job.status === 'Running') {
        const t = setInterval(() => refreshJobDetail(jobId), APP_CONFIG.pollInterval);
        state.pollTimers.push(t);
    }
}

async function refreshJobDetail(jobId) {
    try {
        const job = await apiGet(`/jobs/${jobId}`);
        renderJobDetail(job);
    } catch (err) {
        document.getElementById('job-meta-grid').innerHTML =
            `<div class="alert danger">Error: ${escHtml(err.message)}</div>`;
    }
}

function renderJobDetail(job) {
    document.getElementById('job-detail-title').textContent = `Job ${job.job_id} — ${job.restore_request.database_name}`;

    // Meta info
    const flags = job.governance_flags?.length
        ? job.governance_flags.map(f => `<span class="badge warning" style="margin:2px;">${escHtml(f)}</span>`).join(' ')
        : '<span class="text-muted">None</span>';

    document.getElementById('job-meta-grid').innerHTML = `
        <div style="display:grid;gap:10px;font-size:13px;">
            <div><strong>Status:</strong> ${statusBadge(job.status)}</div>
            <div><strong>Source:</strong> ${escHtml(job.restore_request.source_server)}</div>
            <div><strong>Target:</strong> ${escHtml(job.restore_request.target_server)}</div>
            <div><strong>Database:</strong> ${escHtml(job.restore_request.database_name)}</div>
            <div><strong>Type:</strong> ${escHtml(job.restore_request.restore_type)}</div>
            <div><strong>Requestor:</strong> ${escHtml(job.restore_request.requestor)}</div>
            <div><strong>Approver:</strong> ${escHtml(job.approver || '—')}</div>
            <div><strong>Risk Score:</strong> <span style="color:${riskColor(job.risk_score)};font-weight:700;">${job.risk_score}/100</span></div>
            <div><strong>Flags:</strong> ${flags}</div>
            <div><strong>Created:</strong> ${fmtDate(job.created_at)}</div>
            ${job.duration_seconds ? `<div><strong>Duration:</strong> ${fmtDuration(job.duration_seconds)}</div>` : ''}
            ${job.error_message ? `<div class="alert danger" style="margin-top:8px;"><strong>Error:</strong> ${escHtml(job.error_message)}</div>` : ''}
        </div>`;

    // Action panel
    let actions = '';
    if (job.status === 'AwaitingApproval') {
        actions = `
            <div class="alert warning">⏳ This job requires manual approval before it can execute.</div>
            <button class="btn btn-success" onclick="app.openApprovalModal('${job.job_id}')">✅ Review & Approve</button>`;
    } else if (job.status === 'Approved') {
        actions = `
            <div class="alert info">✅ Approved — ready for execution.</div>
            <button class="btn btn-primary" onclick="app.executeJob('${job.job_id}')">▶️ Execute Restore</button>`;
    } else if (job.status === 'Running') {
        actions = `<div class="alert info">⚙️ Restore is currently executing…</div>`;
    } else if (job.status === 'Completed') {
        actions = `<div class="alert success">✅ Restore completed successfully.</div>`;
    } else if (job.status === 'Failed') {
        actions = `<div class="alert danger">❌ Restore failed. Review logs below.</div>`;
    }
    document.getElementById('job-action-panel').innerHTML = actions;

    // Progress bar
    const progSection = document.getElementById('job-progress-section');
    if (job.status === 'Running') {
        progSection.classList.remove('hidden');
        document.getElementById('job-progress-bar').style.width = job.progress_percent + '%';
        document.getElementById('job-progress-label').textContent = job.progress_percent + '%';
    } else {
        progSection.classList.add('hidden');
    }

    // Logs
    const logHtml = (job.logs || []).map(l => `
        <div class="log-entry">
            <span class="timestamp">${l.timestamp ? new Date(l.timestamp).toLocaleTimeString() : ''}</span>
            <span class="level ${l.level}">${l.level}</span>
            <span class="message">[${escHtml(l.source || '')}] ${escHtml(l.message)}</span>
        </div>`).join('');
    const logViewer = document.getElementById('job-log-viewer');
    logViewer.innerHTML = logHtml || '<div class="text-muted">No logs yet.</div>';
    logViewer.scrollTop = logViewer.scrollHeight;
}

function closeJobDetail() {
    document.getElementById('job-detail-panel').classList.add('hidden');
    state.currentJobId = null;
}

async function executeJob(jobId) {
    try {
        await apiPost(`/restore/execute/${jobId}`, {});
        await refreshJobDetail(jobId);
        // Start polling
        const t = setInterval(() => refreshJobDetail(jobId), APP_CONFIG.pollInterval);
        state.pollTimers.push(t);
    } catch (err) {
        alert('Execute failed: ' + err.message);
    }
}

function navigateAndOpenJob(jobId) {
    navigate('jobs');
    setTimeout(() => openJobDetail(jobId), 300);
}

// ─── Approval Modal ───────────────────────────────────────────────────────────

function openApprovalModal(jobId) {
    state.pendingApprovalJobId = jobId;
    const job = state.jobs.find(j => j.job_id === jobId);
    const info = job
        ? `<p><strong>${escHtml(job.job_id)}</strong> — ${escHtml(job.restore_request.database_name)}<br>
           From: ${escHtml(job.restore_request.source_server)} → ${escHtml(job.restore_request.target_server)}<br>
           Risk Score: <span style="color:${riskColor(job.risk_score)};font-weight:700;">${job.risk_score}</span></p>`
        : `<p>Job: ${escHtml(jobId)}</p>`;
    document.getElementById('approval-job-info').innerHTML = info;
    document.getElementById('approval-modal').classList.remove('hidden');
}

function closeApprovalModal() {
    document.getElementById('approval-modal').classList.add('hidden');
    state.pendingApprovalJobId = null;
}

async function submitApproval(approved) {
    const jobId = state.pendingApprovalJobId;
    if (!jobId) return;
    const approver = document.getElementById('approver-name').value.trim();
    const notes = document.getElementById('approval-notes').value.trim();
    if (!approver) { alert('Approver name/email is required.'); return; }
    try {
        await apiPost(`/restore/approve/${jobId}`, { approved, approver, notes });
        closeApprovalModal();
        await loadJobs();
        if (state.currentJobId === jobId) await refreshJobDetail(jobId);
    } catch (err) {
        alert('Approval action failed: ' + err.message);
    }
}

// ─── Alerts View ──────────────────────────────────────────────────────────────

async function loadAlerts() {
    try {
        const alerts = await apiGet('/alerts');
        state.alerts = alerts;
        renderAlerts(alerts);
    } catch (err) {
        document.getElementById('alerts-container').innerHTML =
            `<div class="alert danger">Failed to load alerts: ${escHtml(err.message)}</div>`;
    }
}

function filterAlerts() {
    const val = document.getElementById('alerts-filter').value;
    let filtered = state.alerts;
    if (val === 'Critical') filtered = filtered.filter(a => a.severity === 'Critical');
    else if (val === 'Warning') filtered = filtered.filter(a => a.severity === 'Warning');
    else if (val === 'false') filtered = filtered.filter(a => !a.acknowledged);
    renderAlerts(filtered);
}

function renderAlerts(alerts) {
    if (!alerts.length) {
        document.getElementById('alerts-container').innerHTML =
            '<div class="empty-state"><div class="icon">✅</div><p>No alerts to display.</p></div>';
        return;
    }
    const html = alerts.map(a => `
        <div style="display:flex;align-items:start;gap:16px;padding:16px;
            border:1px solid ${a.severity === 'Critical' ? 'var(--danger)' : 'var(--warning)'};
            border-radius:10px;margin-bottom:12px;background:${a.severity === 'Critical' ? 'rgba(239,68,68,0.08)' : 'rgba(245,158,11,0.08)'};
            opacity:${a.acknowledged ? '0.55' : '1'};">
            <span style="font-size:32px;">${a.severity === 'Critical' ? '🔴' : '🟡'}</span>
            <div style="flex:1;">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;">
                    <strong>${escHtml(a.server_name)} — Drive ${escHtml(a.drive)}</strong>
                    <div style="display:flex;gap:8px;align-items:center;">
                        ${severityBadge(a.severity)}
                        ${a.acknowledged ? '<span class="badge approved">Acknowledged</span>' : ''}
                    </div>
                </div>
                <div class="text-muted text-sm">${escHtml(a.message)}</div>
                <div style="margin-top:10px;">
                    <div class="progress-container" style="height:8px;">
                        <div class="progress-bar" style="width:${a.used_percent}%;background:${a.used_percent >= 90 ? 'var(--danger)' : 'var(--warning)'};"></div>
                    </div>
                    <div class="text-sm text-muted mt-1">${a.used_percent}% used — ${a.free_gb.toFixed(1)} GB free of ${a.total_gb.toFixed(0)} GB</div>
                </div>
            </div>
            ${!a.acknowledged ? `
                <button class="btn btn-secondary btn-small" onclick="app.acknowledgeAlert('${a.alert_id}')">
                    Acknowledge
                </button>` : ''}
        </div>`).join('');
    document.getElementById('alerts-container').innerHTML = html;
}

async function acknowledgeAlert(alertId) {
    try {
        await apiPost(`/alerts/${alertId}/acknowledge?actor=${encodeURIComponent(APP_CONFIG.currentUser)}`, {});
        await loadAlerts();
    } catch (err) {
        alert('Failed to acknowledge: ' + err.message);
    }
}

// ─── Audit Log View ───────────────────────────────────────────────────────────

async function loadAuditLog() {
    try {
        const entries = await apiGet('/audit/logs?limit=200');
        state.auditLog = entries;
        renderAuditTable(entries);
    } catch (err) {
        document.getElementById('audit-table-container').innerHTML =
            `<div class="alert danger">Failed to load audit log: ${escHtml(err.message)}</div>`;
    }
}

function filterAuditLog() {
    const q = document.getElementById('audit-search').value.toLowerCase().trim();
    if (!q) { renderAuditTable(state.auditLog); return; }
    const filtered = state.auditLog.filter(e =>
        (e.job_id || '').toLowerCase().includes(q) ||
        (e.actor || '').toLowerCase().includes(q) ||
        (e.action || '').toLowerCase().includes(q)
    );
    renderAuditTable(filtered);
}

function renderAuditTable(entries) {
    if (!entries.length) {
        document.getElementById('audit-table-container').innerHTML =
            '<div class="empty-state">No audit entries found.</div>';
        return;
    }
    const resultBadge = r => {
        if (r === 'Success') return `<span class="badge completed">Success</span>`;
        if (r === 'Failure') return `<span class="badge failed">Failure</span>`;
        return `<span class="badge pending">${r}</span>`;
    };
    const rows = entries.map(e => `
        <tr>
            <td>${fmtDate(e.timestamp)}</td>
            <td><code>${escHtml(e.job_id)}</code></td>
            <td><span style="font-size:12px;font-family:'JetBrains Mono',monospace;color:var(--teal);">${escHtml(e.action)}</span></td>
            <td>${escHtml(e.actor)}</td>
            <td>${resultBadge(e.result)}</td>
            <td class="text-sm text-muted">${escHtml(JSON.stringify(e.details || {}).substring(0, 80))}…</td>
        </tr>`).join('');
    document.getElementById('audit-table-container').innerHTML = `
        <table>
            <thead><tr>
                <th>Timestamp</th><th>Job ID</th><th>Action</th>
                <th>Actor</th><th>Result</th><th>Details</th>
            </tr></thead>
            <tbody>${rows}</tbody>
        </table>`;
}

// ─── AI Agent View ────────────────────────────────────────────────────────────

async function runAgentAnalysis() {
    const query = document.getElementById('agent-query').value.trim();
    if (!query) { alert('Please enter a query.'); return; }

    const resultEl = document.getElementById('agent-result');
    const contentEl = document.getElementById('agent-result-content');
    resultEl.classList.remove('hidden');
    contentEl.innerHTML = '<div class="empty-state"><div class="spinner"></div></div>';

    try {
        const result = await apiPost('/agent/analyze', { query });
        renderAgentResult(result);
    } catch (err) {
        contentEl.innerHTML = `<div class="alert danger">Agent error: ${escHtml(err.message)}</div>`;
    }
}

function renderAgentResult(r) {
    const riskHtml = `<span style="color:${riskColor(r.risk_score)};font-size:26px;font-weight:800;">${r.risk_score}</span><span class="text-muted">/100</span>`;
    const govHtml = r.governance_passed
        ? `<span class="badge approved">✅ Governance Passed</span>`
        : `<span class="badge failed">❌ Governance Failed</span>`;
    const flags = r.governance_flags?.length
        ? r.governance_flags.map(f => `<span class="badge warning" style="margin:2px 4px 2px 0;">${escHtml(f)}</span>`).join('')
        : '<span class="text-muted text-sm">None</span>';
    const warnings = r.warnings?.length
        ? r.warnings.map(w => `<div class="alert warning">${escHtml(w)}</div>`).join('')
        : '';
    const workflow = r.suggested_workflow
        ? `<div class="alert info">📜 Suggested Workflow: <strong>${escHtml(r.suggested_workflow)}</strong></div>`
        : '';

    document.getElementById('agent-result-content').innerHTML = `
        <div class="analysis-grid">
            <div class="analysis-cell">
                <div class="cell-label">Intent Detected</div>
                <div class="cell-val text-teal">${escHtml(r.intent)}</div>
            </div>
            <div class="analysis-cell">
                <div class="cell-label">Risk Score</div>
                <div class="cell-val">${riskHtml}</div>
            </div>
            <div class="analysis-cell">
                <div class="cell-label">Governance</div>
                <div class="cell-val">${govHtml}</div>
            </div>
            <div class="analysis-cell">
                <div class="cell-label">Policy Flags</div>
                <div class="cell-val" style="font-size:13px;">${flags}</div>
            </div>
        </div>
        ${warnings}
        ${workflow}
        <div class="card" style="background:rgba(0,0,0,0.25);margin-bottom:12px;">
            <div class="card-title">Recommended Action</div>
            <div style="font-weight:700;color:var(--teal);font-size:14px;">${escHtml(r.recommended_action)}</div>
        </div>
        <div class="card" style="background:rgba(0,0,0,0.25);">
            <div class="card-title">Reasoning</div>
            <div style="line-height:1.8;color:var(--text-secondary);font-size:13.5px;">${escHtml(r.reasoning)}</div>
        </div>`;
}

// ─── Settings ─────────────────────────────────────────────────────────────────

function loadSettings() {
    document.getElementById('setting-api-url').value = APP_CONFIG.apiUrl;
    document.getElementById('setting-poll-interval').value = APP_CONFIG.pollInterval / 1000;
    document.getElementById('setting-user').value = APP_CONFIG.currentUser;
}

function saveSettings() {
    APP_CONFIG.apiUrl = document.getElementById('setting-api-url').value.trim();
    APP_CONFIG.pollInterval = parseInt(document.getElementById('setting-poll-interval').value) * 1000;
    APP_CONFIG.currentUser = document.getElementById('setting-user').value.trim();
    localStorage.setItem('raas_api_url', APP_CONFIG.apiUrl);
    localStorage.setItem('raas_poll_interval', APP_CONFIG.pollInterval / 1000);
    localStorage.setItem('raas_user', APP_CONFIG.currentUser);
    alert('Settings saved. Reconnecting to API...');
    checkApiHealth();
}

// ─── App Object (public API) ──────────────────────────────────────────────────

const app = {
    // Navigation
    navigate,
    navigateAndOpenJob,
    // Dashboard
    loadDashboard,
    // New Restore
    loadNewRestoreForm,
    submitRestoreForm,
    clearForm,
    toggleScheduleTime,
    // Jobs
    loadJobs,
    filterJobs,
    openJobDetail,
    closeJobDetail,
    executeJob,
    // Approval
    openApprovalModal,
    closeApprovalModal,
    submitApproval,
    // Alerts
    loadAlerts,
    filterAlerts,
    acknowledgeAlert,
    // Audit
    loadAuditLog,
    filterAuditLog,
    // Agent
    runAgentAnalysis,
    // Settings
    loadSettings,
    saveSettings,
};

// ─── Bootstrap ────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
    // Wire sidebar navigation
    document.querySelectorAll('.nav-link').forEach(a => {
        a.addEventListener('click', e => {
            e.preventDefault();
            navigate(a.dataset.view);
        });
    });

    // Initial load
    checkApiHealth();
    navigate('dashboard');

    // Refresh API status every 30s
    setInterval(checkApiHealth, 30000);

    // Auto-refresh dashboard KPIs every 30s
    setInterval(() => {
        const activeDashboard = !document.getElementById('view-dashboard').classList.contains('hidden');
        if (activeDashboard) loadDashboard();
    }, 30000);
});
