/*
================================================================================
  RaaS Framework — sp_RegisterRestoreRequest
  
  Purpose : Records every restore request into the central audit table.
            Called by the PowerShell agent and the Python FastAPI layer
            to maintain a complete, tamper-evident audit trail.
            
  Schema  : RaaSInventory.dbo
  
  History :
    2024-01-15  Initial creation
================================================================================
*/

USE [RaaSInventory];
GO

-- ─── Create schema if not exists ─────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raas')
    EXEC sp_executesql N'CREATE SCHEMA [raas] AUTHORIZATION [dbo];';
GO

-- ─── Lookup / Reference Tables ────────────────────────────────────────────────

IF OBJECT_ID('raas.RestoreStatusLookup', 'U') IS NULL
BEGIN
    CREATE TABLE raas.RestoreStatusLookup (
        StatusId    TINYINT      NOT NULL PRIMARY KEY,
        StatusName  VARCHAR(30)  NOT NULL,
        Description NVARCHAR(200) NULL
    );
    INSERT INTO raas.RestoreStatusLookup VALUES
        (1, 'Pending',          'Request received, not yet evaluated'),
        (2, 'AwaitingApproval', 'Governance validation requires manual approval'),
        (3, 'Approved',         'Approved and queued for execution'),
        (4, 'Rejected',         'Rejected by approver or governance engine'),
        (5, 'Running',          'PowerShell restore workflow is executing'),
        (6, 'Completed',        'Restore finished successfully'),
        (7, 'Failed',           'Restore failed — see ErrorDetail'),
        (8, 'Cancelled',        'Cancelled before execution');
END
GO

-- ─── Main Audit Table ────────────────────────────────────────────────────────

IF OBJECT_ID('raas.RestoreAudit', 'U') IS NULL
BEGIN
    CREATE TABLE raas.RestoreAudit (
        AuditId              BIGINT IDENTITY(1,1) NOT NULL,
        JobId                VARCHAR(50)  NOT NULL,
        SourceServer         NVARCHAR(128) NOT NULL,
        TargetServer         NVARCHAR(128) NOT NULL,
        DatabaseName         NVARCHAR(128) NOT NULL,
        RestoreType          VARCHAR(20)  NOT NULL CHECK (RestoreType IN ('Full','Differential','Log')),
        RequestedBy          NVARCHAR(256) NOT NULL,
        ApprovedBy           NVARCHAR(256) NULL,
        ApprovedAt           DATETIME2 NULL,
        StatusId             TINYINT NOT NULL DEFAULT 1,
        RiskScore            TINYINT NOT NULL DEFAULT 0,
        GovernanceFlags      NVARCHAR(1000) NULL,
        BackupPathUsed       NVARCHAR(500) NULL,
        OverwriteExisting    BIT NOT NULL DEFAULT 0,
        ScheduledTime        DATETIME2 NULL,
        StartedAt            DATETIME2 NULL,
        CompletedAt          DATETIME2 NULL,
        DurationSeconds      INT NULL,
        DbccCheckResult      VARCHAR(20) NULL CHECK (DbccCheckResult IN ('PASSED','WARNINGS','FAILED',NULL)),
        ErrorDetail          NVARCHAR(MAX) NULL,
        MachineName          NVARCHAR(128) NULL,
        ExecutedBy           NVARCHAR(256) NULL,
        CreatedAt            DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        UpdatedAt            DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        Justification        NVARCHAR(MAX) NULL,
        RowChecksum          VARBINARY(32) NULL,    -- SHA2_256 for tamper detection

        CONSTRAINT PK_RestoreAudit     PRIMARY KEY CLUSTERED (AuditId),
        CONSTRAINT UQ_RestoreAudit_Job UNIQUE (JobId),
        CONSTRAINT FK_RestoreAudit_Status FOREIGN KEY (StatusId)
            REFERENCES raas.RestoreStatusLookup(StatusId)
    );

    CREATE NONCLUSTERED INDEX IX_RestoreAudit_JobId      ON raas.RestoreAudit (JobId);
    CREATE NONCLUSTERED INDEX IX_RestoreAudit_CreatedAt  ON raas.RestoreAudit (CreatedAt DESC);
    CREATE NONCLUSTERED INDEX IX_RestoreAudit_Servers    ON raas.RestoreAudit (SourceServer, TargetServer);
    CREATE NONCLUSTERED INDEX IX_RestoreAudit_Status     ON raas.RestoreAudit (StatusId, CreatedAt DESC);
END
GO

-- ─── Stored Procedure ────────────────────────────────────────────────────────

CREATE OR ALTER PROCEDURE [dbo].[sp_RegisterRestoreRequest]
    @JobId              VARCHAR(50),
    @SourceServer       NVARCHAR(128),
    @TargetServer       NVARCHAR(128),
    @DatabaseName       NVARCHAR(128),
    @RestoreType        VARCHAR(20)       = 'Full',
    @RequestedBy        NVARCHAR(256)     = NULL,
    @Justification      NVARCHAR(MAX)     = NULL,
    @OverwriteExisting  BIT               = 0,
    @GovernanceFlags    NVARCHAR(1000)    = NULL,
    @RiskScore          TINYINT           = 0,
    @ScheduledTime      DATETIME2         = NULL,
    @Status             VARCHAR(30)       = 'Pending',
    @DurationSeconds    INT               = NULL,
    @ApprovedBy         NVARCHAR(256)     = NULL,
    @ValidationResult   VARCHAR(20)       = NULL,
    @ExecutedBy         NVARCHAR(256)     = NULL,
    @ErrorDetail        NVARCHAR(MAX)     = NULL,
    @CompletedAt        DATETIME2         = NULL,
    @BackupPathUsed     NVARCHAR(500)     = NULL,
    @MachineName        NVARCHAR(128)     = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ── Input Validation ───────────────────────────────────────────────────
    IF @JobId IS NULL OR LEN(LTRIM(RTRIM(@JobId))) = 0
    BEGIN
        RAISERROR('JobId cannot be null or empty.', 16, 1);
        RETURN;
    END

    IF @SourceServer = @TargetServer
    BEGIN
        RAISERROR('Source and Target servers cannot be the same instance for a restore operation.', 16, 1);
        RETURN;
    END

    IF @RestoreType NOT IN ('Full', 'Differential', 'Log')
    BEGIN
        RAISERROR('Invalid RestoreType. Accepted values: Full, Differential, Log.', 16, 1);
        RETURN;
    END

    -- ── Resolve Status ID ──────────────────────────────────────────────────
    DECLARE @StatusId TINYINT;
    SELECT @StatusId = StatusId
    FROM   raas.RestoreStatusLookup
    WHERE  StatusName = @Status;

    IF @StatusId IS NULL
    BEGIN
        -- Default to Pending if status name not recognized
        SET @StatusId = 1;
    END

    -- ── Compute row checksum for tamper detection ──────────────────────────
    DECLARE @ChecksumInput NVARCHAR(MAX) =
        @JobId + '|' + ISNULL(@SourceServer, '') + '|' +
        ISNULL(@TargetServer, '') + '|' + ISNULL(@DatabaseName, '') + '|' +
        ISNULL(@RequestedBy, '') + '|' + CAST(SYSUTCDATETIME() AS NVARCHAR(50));
    DECLARE @RowChecksum VARBINARY(32) = HASHBYTES('SHA2_256', @ChecksumInput);

    -- ── UPSERT: Insert on first call, update on subsequent status updates ──
    BEGIN TRANSACTION;

    IF NOT EXISTS (SELECT 1 FROM raas.RestoreAudit WHERE JobId = @JobId)
    BEGIN
        INSERT INTO raas.RestoreAudit (
            JobId, SourceServer, TargetServer, DatabaseName, RestoreType,
            RequestedBy, Justification, OverwriteExisting, GovernanceFlags,
            RiskScore, ScheduledTime, StatusId, ExecutedBy, MachineName,
            BackupPathUsed, RowChecksum
        )
        VALUES (
            @JobId, @SourceServer, @TargetServer, @DatabaseName, @RestoreType,
            ISNULL(@RequestedBy, SYSTEM_USER), @Justification, @OverwriteExisting,
            @GovernanceFlags, @RiskScore, @ScheduledTime, @StatusId,
            ISNULL(@ExecutedBy, SYSTEM_USER), ISNULL(@MachineName, HOST_NAME()),
            @BackupPathUsed, @RowChecksum
        );
    END
    ELSE
    BEGIN
        UPDATE raas.RestoreAudit SET
            StatusId         = @StatusId,
            ApprovedBy       = ISNULL(@ApprovedBy, ApprovedBy),
            ApprovedAt       = CASE WHEN @ApprovedBy IS NOT NULL THEN SYSUTCDATETIME() ELSE ApprovedAt END,
            DurationSeconds  = ISNULL(@DurationSeconds, DurationSeconds),
            DbccCheckResult  = ISNULL(@ValidationResult, DbccCheckResult),
            ErrorDetail      = ISNULL(@ErrorDetail, ErrorDetail),
            CompletedAt      = ISNULL(@CompletedAt, CompletedAt),
            BackupPathUsed   = ISNULL(@BackupPathUsed, BackupPathUsed),
            ExecutedBy       = ISNULL(@ExecutedBy, ExecutedBy),
            UpdatedAt        = SYSUTCDATETIME()
        WHERE JobId = @JobId;
    END

    COMMIT TRANSACTION;

    -- ── Return the inserted/updated record ────────────────────────────────
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
        s.StatusName AS Status,
        a.RiskScore,
        a.GovernanceFlags,
        a.DurationSeconds,
        a.DbccCheckResult,
        a.ErrorDetail,
        a.CreatedAt,
        a.UpdatedAt
    FROM raas.RestoreAudit a
    JOIN raas.RestoreStatusLookup s ON a.StatusId = s.StatusId
    WHERE a.JobId = @JobId;

    RETURN 0;
END
GO

PRINT 'sp_RegisterRestoreRequest created/updated successfully.';
GO
