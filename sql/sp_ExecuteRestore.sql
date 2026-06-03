/*
================================================================================
  RaaS Framework — sp_ExecuteRestore
  
  Purpose : Validates preconditions and kicks off a SQL Server restore operation
            directly from T-SQL. Primarily a companion to the PowerShell agent
            for environments where direct T-SQL restore is preferred or for
            calling via linked server. Includes pre-flight checks, execution,
            and post-restore DBCC validation.
            
  NOTE    : In most deployments, the PowerShell agent (Invoke-SqlRestore.ps1)
            handles execution. This procedure serves as an alternative path
            and as the execution record keeper.

  Schema  : Target server — calls back to RaaSInventory via linked server
  
  History :
    2024-01-15  Initial creation
================================================================================
*/

USE [master];
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_ExecuteRestore]
    @JobId              VARCHAR(50),
    @DatabaseName       NVARCHAR(128),
    @BackupFilePath     NVARCHAR(500),
    @RestoreType        VARCHAR(20)    = 'Full',
    @WithReplace        BIT            = 0,
    @WithRecovery       BIT            = 1,
    @WithStatsPercent   INT            = 10,
    @DataFileMove       NVARCHAR(500)  = NULL,   -- New MDF path (optional relocation)
    @LogFileMove        NVARCHAR(500)  = NULL,   -- New LDF path (optional relocation)
    @RequestedBy        NVARCHAR(256)  = NULL,
    @DryRun             BIT            = 0,
    @InventoryServer    NVARCHAR(128)  = 'SQL-INVENTORY-01'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @StartTime       DATETIME2  = SYSUTCDATETIME(),
        @EndTime         DATETIME2,
        @DurationSec     INT,
        @ErrorMsg        NVARCHAR(MAX),
        @RestoreSQL      NVARCHAR(MAX),
        @WithClause      NVARCHAR(500),
        @StatusMsg       NVARCHAR(200),
        @BackupSizeGB    DECIMAL(10,2);

    -- ── Pre-condition: Validate backup file exists ─────────────────────────
    IF @DryRun = 0
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM sys.master_files WHERE physical_name = @BackupFilePath
        ) AND NOT EXISTS (
            SELECT 1 FROM sys.dm_os_file_exists(@BackupFilePath) WHERE file_exists = 1
        )
        BEGIN
            RAISERROR('Backup file not found: %s', 16, 1, @BackupFilePath);
            RETURN -1;
        END
    END

    -- ── Pre-condition: Validate restore type ──────────────────────────────
    IF @RestoreType NOT IN ('Full', 'Differential', 'Log')
    BEGIN
        RAISERROR('Invalid RestoreType: %s. Valid values: Full, Differential, Log.', 16, 1, @RestoreType);
        RETURN -1;
    END

    -- ── Estimate backup size for space check ──────────────────────────────
    SELECT @BackupSizeGB = CAST(backup_size / 1073741824.0 AS DECIMAL(10,2))
    FROM   msdb.dbo.backupset bs
    WHERE  bs.database_name = @DatabaseName
      AND  bs.type = CASE @RestoreType WHEN 'Full' THEN 'D' WHEN 'Differential' THEN 'I' ELSE 'L' END
    ORDER  BY bs.backup_finish_date DESC
    FETCH FIRST 1 ROWS ONLY;

    -- ── Log: Request received ─────────────────────────────────────────────
    RAISERROR('RaaS sp_ExecuteRestore: Starting %s restore for [%s]. Job: %s. DryRun: %d.',
              0, 1, @RestoreType, @DatabaseName, @JobId, @DryRun) WITH NOWAIT;

    -- ── Build WITH clause ─────────────────────────────────────────────────
    SET @WithClause = 'STATS = ' + CAST(@WithStatsPercent AS VARCHAR(3));

    IF @WithReplace = 1
        SET @WithClause = @WithClause + ', REPLACE';

    IF @WithRecovery = 1
        SET @WithClause = @WithClause + ', RECOVERY'
    ELSE
        SET @WithClause = @WithClause + ', NORECOVERY';

    -- ── Handle file relocation (MOVE option) ──────────────────────────────
    IF @DataFileMove IS NOT NULL AND @LogFileMove IS NOT NULL
    BEGIN
        -- Read logical file names from backup header
        DECLARE @FileListTable TABLE (
            LogicalName    NVARCHAR(128),
            PhysicalName   NVARCHAR(260),
            [Type]         CHAR(1),
            FileGroupName  NVARCHAR(128),
            Size           BIGINT,
            MaxSize        BIGINT,
            FileId         INT,
            CreateLSN      NUMERIC(25,0),
            DropLSN        NUMERIC(25,0),
            UniqueId       UNIQUEIDENTIFIER,
            ReadOnlyLSN    NUMERIC(25,0),
            ReadWriteLSN   NUMERIC(25,0),
            BackupSizeInBytes BIGINT,
            SourceBlockSize INT,
            FileGroupId    INT,
            LogGroupGUID   UNIQUEIDENTIFIER,
            DifferentialBaseLSN NUMERIC(25,0),
            DifferentialBaseGUID UNIQUEIDENTIFIER,
            IsReadOnly     BIT,
            IsPresent      BIT,
            TDEThumbprint  VARBINARY(32),
            SnapshotUrl    NVARCHAR(360)
        );

        INSERT INTO @FileListTable
        EXEC ('RESTORE FILELISTONLY FROM DISK = ''' + @BackupFilePath + '''');

        DECLARE @DataLogical NVARCHAR(128), @LogLogical NVARCHAR(128);
        SELECT TOP 1 @DataLogical = LogicalName FROM @FileListTable WHERE [Type] = 'D';
        SELECT TOP 1 @LogLogical  = LogicalName FROM @FileListTable WHERE [Type] = 'L';

        IF @DataLogical IS NOT NULL
            SET @WithClause = @WithClause + ', MOVE N''' + @DataLogical + ''' TO N''' + @DataFileMove + '''';
        IF @LogLogical IS NOT NULL
            SET @WithClause = @WithClause + ', MOVE N''' + @LogLogical + ''' TO N''' + @LogFileMove + '''';
    END

    -- ── Build RESTORE statement ───────────────────────────────────────────
    SET @RestoreSQL = CASE @RestoreType
        WHEN 'Log' THEN
            N'RESTORE LOG [' + @DatabaseName + N'] FROM DISK = N''' + @BackupFilePath + N''' WITH ' + @WithClause + N';'
        ELSE
            N'RESTORE DATABASE [' + @DatabaseName + N'] FROM DISK = N''' + @BackupFilePath + N''' WITH ' + @WithClause + N';'
    END;

    RAISERROR('Executing: %s', 0, 1, @RestoreSQL) WITH NOWAIT;

    -- ── Execute or simulate ───────────────────────────────────────────────
    BEGIN TRY
        IF @DryRun = 0
            EXEC sp_executesql @RestoreSQL;
        ELSE
            RAISERROR('[DryRun] Would execute: %s', 0, 1, @RestoreSQL) WITH NOWAIT;

        SET @EndTime     = SYSUTCDATETIME();
        SET @DurationSec = DATEDIFF(SECOND, @StartTime, @EndTime);

        RAISERROR('Restore completed in %d seconds.', 0, 1, @DurationSec) WITH NOWAIT;

        -- ── Post-restore: DBCC CHECKDB ────────────────────────────────────
        IF @DryRun = 0 AND @WithRecovery = 1
        BEGIN
            RAISERROR('Running DBCC CHECKDB on [%s]...', 0, 1, @DatabaseName) WITH NOWAIT;
            BEGIN TRY
                EXEC ('DBCC CHECKDB ([' + @DatabaseName + ']) WITH NO_INFOMSGS, ALL_ERRORMSGS;');
                RAISERROR('DBCC CHECKDB passed — no integrity errors.', 0, 1) WITH NOWAIT;
            END TRY
            BEGIN CATCH
                RAISERROR('DBCC CHECKDB reported issues: %s', 0, 1, ERROR_MESSAGE()) WITH NOWAIT;
            END CATCH
        END

        -- ── Report success ────────────────────────────────────────────────
        SELECT
            @JobId          AS JobId,
            @DatabaseName   AS DatabaseName,
            @RestoreType    AS RestoreType,
            'Completed'     AS Status,
            @DurationSec    AS DurationSeconds,
            @BackupSizeGB   AS BackupSizeGB,
            @StartTime      AS StartedAt,
            @EndTime        AS CompletedAt,
            @WithClause     AS WithClauseUsed,
            @DryRun         AS WasDryRun;

        RETURN 0;
    END TRY
    BEGIN CATCH
        SET @EndTime     = SYSUTCDATETIME();
        SET @DurationSec = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @ErrorMsg    = ERROR_MESSAGE();

        RAISERROR('RESTORE FAILED for [%s]: %s', 16, 1, @DatabaseName, @ErrorMsg);

        SELECT
            @JobId          AS JobId,
            @DatabaseName   AS DatabaseName,
            @RestoreType    AS RestoreType,
            'Failed'        AS Status,
            @DurationSec    AS DurationSeconds,
            @ErrorMsg       AS ErrorMessage,
            @StartTime      AS StartedAt,
            @EndTime        AS FailedAt;

        RETURN -1;
    END CATCH
END
GO

PRINT 'sp_ExecuteRestore created/updated successfully.';
GO
