/*
================================================================================
  RaaS Framework — sp_GetRestoreAuditLog
  
  Purpose : Retrieves restore audit history with flexible filtering.
            Used by the Python agent, UI, and reporting tools to surface
            restore history, compliance evidence, and trend analysis.
            
  Schema  : RaaSInventory.dbo
  
  History :
    2024-01-15  Initial creation
================================================================================
*/

USE [RaaSInventory];
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_GetRestoreAuditLog]
    -- ── Filters ─────────────────────────────────────────────────────────────
    @JobId              VARCHAR(50)     = NULL,   -- Filter by specific job
    @SourceServer       NVARCHAR(128)   = NULL,   -- Filter by source server
    @TargetServer       NVARCHAR(128)   = NULL,   -- Filter by target server
    @DatabaseName       NVARCHAR(128)   = NULL,   -- Filter by database name
    @RequestedBy        NVARCHAR(256)   = NULL,   -- Filter by requestor
    @Status             VARCHAR(30)     = NULL,   -- Filter by status name
    @RestoreType        VARCHAR(20)     = NULL,   -- Filter by Full/Differential/Log
    @FromDate           DATETIME2       = NULL,   -- Start of date range
    @ToDate             DATETIME2       = NULL,   -- End of date range (inclusive)
    -- ── Output control ──────────────────────────────────────────────────────
    @IncludeSuccessOnly BIT             = 0,      -- When 1, return only Completed jobs
    @IncludeFailedOnly  BIT             = 0,      -- When 1, return only Failed jobs
    @TopN               INT             = 200,    -- Max rows to return
    @OrderByColumn      VARCHAR(30)     = 'CreatedAt',
    @OrderDirection     VARCHAR(4)      = 'DESC',
    -- ── Summary mode ────────────────────────────────────────────────────────
    @SummaryOnly        BIT             = 0       -- Return aggregated stats instead
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Input validation ──────────────────────────────────────────────────
    IF @TopN IS NULL OR @TopN <= 0 SET @TopN = 200;
    IF @TopN > 10000               SET @TopN = 10000;

    IF @OrderDirection NOT IN ('ASC', 'DESC')
    BEGIN
        RAISERROR('OrderDirection must be ASC or DESC.', 16, 1);
        RETURN;
    END

    IF @FromDate IS NULL SET @FromDate = DATEADD(DAY, -90, SYSUTCDATETIME());
    IF @ToDate   IS NULL SET @ToDate   = SYSUTCDATETIME();

    -- ── Summary mode: aggregate stats ─────────────────────────────────────
    IF @SummaryOnly = 1
    BEGIN
        SELECT
            COUNT(*)                                            AS TotalRestores,
            SUM(CASE WHEN s.StatusName = 'Completed' THEN 1 ELSE 0 END) AS SuccessCount,
            SUM(CASE WHEN s.StatusName = 'Failed'    THEN 1 ELSE 0 END) AS FailureCount,
            SUM(CASE WHEN s.StatusName IN ('AwaitingApproval','Pending') THEN 1 ELSE 0 END) AS PendingCount,
            CAST(
                SUM(CASE WHEN s.StatusName = 'Completed' THEN 1.0 ELSE 0 END) /
                NULLIF(SUM(CASE WHEN s.StatusName IN ('Completed','Failed') THEN 1 ELSE 0 END), 0) * 100
            AS DECIMAL(5,1))                                   AS SuccessRatePct,
            AVG(CASE WHEN s.StatusName = 'Completed' THEN a.DurationSeconds END) AS AvgDurationSeconds,
            MAX(CASE WHEN s.StatusName = 'Completed' THEN a.DurationSeconds END) AS MaxDurationSeconds,
            MIN(CASE WHEN s.StatusName = 'Completed' THEN a.DurationSeconds END) AS MinDurationSeconds,
            MIN(a.CreatedAt)                                   AS EarliestRestore,
            MAX(a.CreatedAt)                                   AS LatestRestore
        FROM raas.RestoreAudit a
        JOIN raas.RestoreStatusLookup s ON a.StatusId = s.StatusId
        WHERE a.CreatedAt BETWEEN @FromDate AND @ToDate
          AND (@SourceServer  IS NULL OR a.SourceServer  LIKE '%' + @SourceServer + '%')
          AND (@TargetServer  IS NULL OR a.TargetServer  LIKE '%' + @TargetServer + '%')
          AND (@DatabaseName  IS NULL OR a.DatabaseName  LIKE '%' + @DatabaseName + '%')
          AND (@RequestedBy   IS NULL OR a.RequestedBy   LIKE '%' + @RequestedBy + '%')
          AND (@Status        IS NULL OR s.StatusName     = @Status)
          AND (@RestoreType   IS NULL OR a.RestoreType    = @RestoreType);
        RETURN;
    END

    -- ── Detail mode: individual audit rows ────────────────────────────────
    ;WITH FilteredAudit AS (
        SELECT
            a.AuditId,
            a.JobId,
            a.SourceServer,
            a.TargetServer,
            a.DatabaseName,
            a.RestoreType,
            a.RequestedBy,
            a.ApprovedBy,
            a.ApprovedAt,
            s.StatusName                    AS Status,
            a.RiskScore,
            CASE
                WHEN a.RiskScore <= 30 THEN 'Low'
                WHEN a.RiskScore <= 60 THEN 'Medium'
                WHEN a.RiskScore <= 80 THEN 'High'
                ELSE 'Critical'
            END                             AS RiskLabel,
            a.GovernanceFlags,
            a.OverwriteExisting,
            a.ScheduledTime,
            a.StartedAt,
            a.CompletedAt,
            a.DurationSeconds,
            CAST(a.DurationSeconds / 60.0 AS DECIMAL(8,1)) AS DurationMinutes,
            a.DbccCheckResult,
            a.BackupPathUsed,
            a.ErrorDetail,
            a.ExecutedBy,
            a.MachineName,
            a.CreatedAt,
            a.UpdatedAt,
            a.Justification,
            -- Compliance: was this a production target?
            CASE WHEN a.TargetServer LIKE '%-PROD-%' OR a.TargetServer LIKE 'PROD%' THEN 1 ELSE 0 END
                                            AS IsProductionTarget,
            -- SLA: restores should complete within 4 hours
            CASE
                WHEN a.DurationSeconds > 14400 THEN 'SLA_BREACHED'
                WHEN a.DurationSeconds > 7200  THEN 'SLA_AT_RISK'
                ELSE 'SLA_MET'
            END                             AS SlaStatus,
            ROW_NUMBER() OVER (ORDER BY
                CASE WHEN @OrderByColumn = 'CreatedAt'       AND @OrderDirection = 'DESC' THEN a.CreatedAt       END DESC,
                CASE WHEN @OrderByColumn = 'CreatedAt'       AND @OrderDirection = 'ASC'  THEN a.CreatedAt       END ASC,
                CASE WHEN @OrderByColumn = 'DurationSeconds' AND @OrderDirection = 'DESC' THEN a.DurationSeconds END DESC,
                CASE WHEN @OrderByColumn = 'DurationSeconds' AND @OrderDirection = 'ASC'  THEN a.DurationSeconds END ASC,
                CASE WHEN @OrderByColumn = 'RiskScore'       AND @OrderDirection = 'DESC' THEN a.RiskScore       END DESC,
                CASE WHEN @OrderByColumn = 'RiskScore'       AND @OrderDirection = 'ASC'  THEN a.RiskScore       END ASC,
                a.CreatedAt DESC
            ) AS RowNum
        FROM raas.RestoreAudit a
        JOIN raas.RestoreStatusLookup s ON a.StatusId = s.StatusId
        WHERE
            a.CreatedAt BETWEEN @FromDate AND @ToDate
          AND (@JobId         IS NULL OR a.JobId         = @JobId)
          AND (@SourceServer  IS NULL OR a.SourceServer  LIKE '%' + @SourceServer + '%')
          AND (@TargetServer  IS NULL OR a.TargetServer  LIKE '%' + @TargetServer + '%')
          AND (@DatabaseName  IS NULL OR a.DatabaseName  LIKE '%' + @DatabaseName + '%')
          AND (@RequestedBy   IS NULL OR a.RequestedBy   LIKE '%' + @RequestedBy + '%')
          AND (@Status        IS NULL OR s.StatusName     = @Status)
          AND (@RestoreType   IS NULL OR a.RestoreType    = @RestoreType)
          AND (@IncludeSuccessOnly = 0 OR s.StatusName = 'Completed')
          AND (@IncludeFailedOnly  = 0 OR s.StatusName = 'Failed')
    )
    SELECT
        AuditId, JobId, SourceServer, TargetServer, DatabaseName,
        RestoreType, RequestedBy, ApprovedBy, ApprovedAt,
        Status, RiskScore, RiskLabel, GovernanceFlags,
        OverwriteExisting, ScheduledTime, StartedAt, CompletedAt,
        DurationSeconds, DurationMinutes, DbccCheckResult,
        BackupPathUsed, ErrorDetail, ExecutedBy, MachineName,
        CreatedAt, UpdatedAt, Justification,
        IsProductionTarget, SlaStatus
    FROM FilteredAudit
    WHERE RowNum <= @TopN
    ORDER BY RowNum;

    RETURN 0;
END
GO

PRINT 'sp_GetRestoreAuditLog created/updated successfully.';
GO

-- ─── Example Usage ────────────────────────────────────────────────────────────
/*
-- Get all restores in the last 7 days
EXEC dbo.sp_GetRestoreAuditLog @FromDate = DATEADD(DAY, -7, GETUTCDATE());

-- Get only failed restores for production targets
EXEC dbo.sp_GetRestoreAuditLog @TargetServer = 'PROD', @IncludeFailedOnly = 1;

-- Get summary stats for the last 30 days
EXEC dbo.sp_GetRestoreAuditLog @SummaryOnly = 1, @FromDate = DATEADD(DAY, -30, GETUTCDATE());

-- Get audit trail for a specific job
EXEC dbo.sp_GetRestoreAuditLog @JobId = 'JOB-ABC12345';

-- Top 10 longest restores
EXEC dbo.sp_GetRestoreAuditLog @TopN = 10, @OrderByColumn = 'DurationSeconds', @OrderDirection = 'DESC';
*/
