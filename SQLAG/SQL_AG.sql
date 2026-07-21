/*
Needs to run in SQLCMD Mode
*/

:ON ERROR EXIT
SET NOCOUNT ON;

--------------------------------------------------------------------------------
-- Global user parameters
--------------------------------------------------------------------------------
:setvar BackupShare "\\VMSQLAGTEST01\ReplShare"
:setvar CertName "20241003_nonprod"       -- leave "" to skip TDE cert check
:setvar Verbose 0                         -- 1=print generated commands, 0=quiet
:setvar OverwriteIfExists 1               -- 1=allow REPLACE on restore, 0=disallow
:setvar AddJoinWaitSeconds 30             -- max wait for AG "ADD DATABASE" to appear

--------------------------------------------------------------------------------
-- Workload definitions (edit these only)
--------------------------------------------------------------------------------
-- Workload 1
:setvar WL1_Label  "ACURITY2019"
:setvar WL1_DBList "Test"
:setvar WL1_Src    "VMSQLAGTEST01\ACURITY2019"
:setvar WL1_Tgt    "VMSQLAGTEST02\ACURITY2019"
:setvar WL1_AG     "ACURITY2019AG"

-- Workload 2
:setvar WL2_Label  "REPL2019"
:setvar WL2_DBList "Test"
:setvar WL2_Src    "VMSQLAGTEST01\REPL2019"
:setvar WL2_Tgt    "VMSQLAGTEST02\REPL2019"
:setvar WL2_AG     "REPL2019AG"

-- Workload 3
:setvar WL3_Label  "NWDB2019"
:setvar WL3_DBList "TestNWDB"
:setvar WL3_Src    "VMSQLAGTEST01\NWDB2019"
:setvar WL3_Tgt    "VMSQLAGTEST02\NWDB2019"
:setvar WL3_AG     "NWDB2019AG"

--------------------------------------------------------------------------------
-- (Optional) quick variable expansion sanity check (uncomment to debug)
--------------------------------------------------------------------------------
--PRINT 'WL1_Src=' + '$(WL1_Src)';
--PRINT 'WL1_Tgt=' + '$(WL1_Tgt)';
--PRINT 'WL2_Src=' + '$(WL2_Src)';
--PRINT 'WL2_Tgt=' + '$(WL2_Tgt)';
--PRINT 'WL3_Src=' + '$(WL3_Src)';
--PRINT 'WL3_Tgt=' + '$(WL3_Tgt)';
--GO

--------------------------------------------------------------------------------
-- Helper macro: split CSV list into #DBs
--------------------------------------------------------------------------------
:setvar MakeDbList "
IF OBJECT_ID('tempdb..#DBs') IS NOT NULL DROP TABLE #DBs;
CREATE TABLE #DBs(name sysname NOT NULL PRIMARY KEY);
WITH S AS (SELECT value FROM STRING_SPLIT(@DBList, ','))
INSERT #DBs(name)
SELECT DISTINCT CONVERT(sysname, TRIM(value))
FROM S
WHERE TRIM(value) IS NOT NULL AND TRIM(value) <> '';
IF NOT EXISTS (SELECT 1 FROM #DBs)
BEGIN
    DECLARE @ErrMsg_MDL NVARCHAR(2048) = N'No databases specified for workload: $(WL_Label).';
    THROW 51010, @ErrMsg_MDL, 1;
END
"

--------------------------------------------------------------------------------
-- Macro: Backup FULL + LOG on source
--------------------------------------------------------------------------------
:setvar DoBackupOnSource "
DECLARE @db sysname;

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM #DBs ORDER BY name;
OPEN cur;
FETCH NEXT FROM cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @db AND database_id > 4)
    BEGIN
        DECLARE @ErrMsg1 NVARCHAR(2048) = N'Source $(WL_Label): Database not found or is a system DB: ' + @db;
        THROW 51011, @ErrMsg1, 1;
    END

    IF EXISTS (SELECT 1 FROM sys.databases WHERE name=@db AND recovery_model_desc <> 'FULL')
    BEGIN
        DECLARE @ErrMsg2 NVARCHAR(2048) = N'Source $(WL_Label): Database not in FULL recovery: ' + @db;
        THROW 51012, @ErrMsg2, 1;
    END

    DECLARE @fullPath NVARCHAR(4000) = @BackupShare + N'\' + @db + N'_FULL.bak';
    DECLARE @logPath  NVARCHAR(4000) = @BackupShare + N'\' + @db + N'_LOG.trn';

    DECLARE @sql_full NVARCHAR(MAX) =
        N'BACKUP DATABASE ' + QUOTENAME(@db) +
        N' TO DISK = N''' + REPLACE(@fullPath, '''', '''''') + N''' ' +
        N'WITH COPY_ONLY, INIT, COMPRESSION, STATS = 5;';
    IF @Verbose = 1 RAISERROR(N'-- BACKUP FULL ($(WL_Label)): %s', 0, 1, @sql_full) WITH NOWAIT;
    EXEC (@sql_full);

    DECLARE @sql_log NVARCHAR(MAX) =
        N'BACKUP LOG ' + QUOTENAME(@db) +
        N' TO DISK = N''' + REPLACE(@logPath, '''', '''''') + N''' ' +
        N'WITH INIT, COMPRESSION, STATS = 5;';
    IF @Verbose = 1 RAISERROR(N'-- BACKUP LOG  ($(WL_Label)): %s', 0, 1, @sql_log) WITH NOWAIT;
    EXEC (@sql_log);

    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;
"

--------------------------------------------------------------------------------
-- Macro: Restore FULL + LOG (NORECOVERY) on target
--------------------------------------------------------------------------------
:setvar DoRestoreOnTarget "
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = @AGName)
BEGIN
    DECLARE @ErrMsgAG NVARCHAR(2048) = N'Target $(WL_Label): Availability Group not found: ' + @AGName;
    THROW 51020, @ErrMsgAG, 1;
END

IF @CertName IS NOT NULL AND NOT EXISTS (SELECT 1 FROM master.sys.certificates WHERE name = @CertName)
BEGIN
    DECLARE @ErrMsgCert NVARCHAR(2048) = N'Target $(WL_Label): TDE certificate not present: ' + @CertName;
    THROW 51021, @ErrMsgCert, 1;
END

DECLARE @db sysname;

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM #DBs ORDER BY name;
OPEN cur;
FETCH NEXT FROM cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @fullPath NVARCHAR(4000) = @BackupShare + N'\' + @db + N'_FULL.bak';
    DECLARE @logPath  NVARCHAR(4000) = @BackupShare + N'\' + @db + N'_LOG.trn';

    -- If DB exists and is not RESTORING, enforce overwrite policy
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @db AND state_desc <> 'RESTORING')
    BEGIN
        IF @Overwrite <> 1
        BEGIN
            DECLARE @ErrExists NVARCHAR(4000) =
                N'Target ' + @@SERVERNAME + N': Database ' + QUOTENAME(@db) +
                N' already exists and is not in RESTORING. Set OverwriteIfExists=1 to REPLACE.';
            THROW 51061, @ErrExists, 1;
        END
    END

    -- If the DB is locally joined (previous run), take it out ONLY if this node is SECONDARY
    DECLARE @LocalRole NVARCHAR(60) =
        (SELECT TOP(1) rs.role_desc
         FROM sys.availability_groups ag
         JOIN sys.dm_hadr_availability_replica_states rs
           ON ag.group_id = rs.group_id AND rs.is_local = 1
         WHERE ag.name = @AGName);

    DECLARE @IsLocalPrimary BIT = CASE WHEN @LocalRole = 'PRIMARY' THEN 1 ELSE 0 END;

    DECLARE @IsDbJoinedLocally BIT =
    (
        SELECT CASE WHEN EXISTS (
            SELECT 1
            FROM sys.dm_hadr_database_replica_states drs
            JOIN sys.databases d ON drs.database_id = d.database_id
            WHERE d.name = @db AND drs.is_local = 1
        ) THEN 1 ELSE 0 END
    );

    IF @IsDbJoinedLocally = 1 AND @IsLocalPrimary = 1
    BEGIN
        DECLARE @ErrPrimaryJoined NVARCHAR(4000) =
            N'Target ' + @@SERVERNAME + N': Database ' + QUOTENAME(@db) +
            N' is already joined to AG ' + QUOTENAME(@AGName) + N' on the PRIMARY. Aborting to avoid data loss.';
        THROW 51060, @ErrPrimaryJoined, 1;
    END

    IF @IsDbJoinedLocally = 1 AND @IsLocalPrimary = 0
    BEGIN
        DECLARE @sqlHadrOff NVARCHAR(MAX) =
            N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET HADR OFF;';
        IF @Verbose = 1 RAISERROR(N'-- HADR OFF ($(WL_Label)): %s', 0, 1, @sqlHadrOff) WITH NOWAIT;
        EXEC(@sqlHadrOff);
    END

    -- Discover files and build MOVE clauses
    IF OBJECT_ID('tempdb..#files') IS NOT NULL DROP TABLE #files;
    CREATE TABLE #files
    (
        LogicalName sysname,
        PhysicalName NVARCHAR(260),
        [Type] CHAR(1),
        FileGroupName sysname NULL,
        Size BIGINT,
        MaxSize BIGINT,
        FileId INT,
        CreateLSN NUMERIC(25,0),
        DropLSN NUMERIC(25,0) NULL,
        UniqueId UNIQUEIDENTIFIER,
        ReadOnlyLSN NUMERIC(25,0) NULL,
        ReadWriteLSN NUMERIC(25,0) NULL,
        BackupSizeInBytes BIGINT,
        SourceBlockSize INT,
        FileGroupId INT NULL,
        LogGroupGUID UNIQUEIDENTIFIER NULL,
        DifferentialBaseLSN NUMERIC(25,0) NULL,
        DifferentialBaseGUID UNIQUEIDENTIFIER NULL,
        IsReadOnly BIT,
        IsPresent BIT,
        TDEThumbprint VARBINARY(32) NULL,
        SnapshotUrl VARCHAR(100)
    );

    DECLARE @sqlFileList NVARCHAR(MAX) =
        N'RESTORE FILELISTONLY FROM DISK = N''' + REPLACE(@fullPath, '''', '''''') + N'''';
    IF @Verbose = 1 RAISERROR(N'-- FILELISTONLY ($(WL_Label)): %s', 0, 1, @sqlFileList) WITH NOWAIT;

    INSERT #files
    EXEC(@sqlFileList);

    IF NOT EXISTS (SELECT 1 FROM #files)
    BEGIN
        DECLARE @ErrMsgFileList NVARCHAR(2048) = N'Target $(WL_Label): FILELISTONLY returned no rows for ' + @fullPath;
        THROW 51023, @ErrMsgFileList, 1;
    END

    DECLARE @dataPath NVARCHAR(4000)      = CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
    DECLARE @logPathDefault NVARCHAR(4000)= CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultLogPath'));
    IF @dataPath IS NULL OR @logPathDefault IS NULL
    BEGIN
        DECLARE @ErrMsgPaths NVARCHAR(2048) = N'Target $(WL_Label): Default data/log paths not available on this version.';
        THROW 51024, @ErrMsgPaths, 1;
    END

    IF RIGHT(@dataPath, 1) <> '\' SET @dataPath = @dataPath + '\';
    IF RIGHT(@logPathDefault, 1) <> '\' SET @logPathDefault = @logPathDefault + '\';

    DECLARE @moveClauses NVARCHAR(MAX) =
    (
        SELECT STRING_AGG(
            N'MOVE N''' + f.LogicalName + N''' TO N''' +
            CASE WHEN f.[Type] = 'L'
                 THEN @logPathDefault + f.LogicalName + N'.ldf'
                 ELSE @dataPath + f.LogicalName +
                      CASE WHEN f.FileId = 1 THEN N'.mdf' ELSE N'.ndf' END
            END + N''''
        , N', ')
        FROM #files f
    );
    IF @moveClauses IS NULL SET @moveClauses = N'';

    DECLARE @withOptions NVARCHAR(MAX) = N'WITH NORECOVERY';
    IF @Overwrite = 1 SET @withOptions += N', REPLACE';
    IF @moveClauses <> N'' SET @withOptions += N', ' + @moveClauses;

    DECLARE @restoreFull NVARCHAR(MAX) =
        N'RESTORE DATABASE ' + QUOTENAME(@db) +
        N' FROM DISK = N''' + REPLACE(@fullPath, '''', '''''') + N''' ' +
        @withOptions + N';';
    IF @Verbose = 1 RAISERROR(N'-- RESTORE FULL ($(WL_Label)): %s', 0, 1, @restoreFull) WITH NOWAIT;
    EXEC(@restoreFull);

    DECLARE @restoreLog NVARCHAR(MAX) =
        N'RESTORE LOG ' + QUOTENAME(@db) +
        N' FROM DISK = N''' + REPLACE(@logPath, '''', '''''') + N''' WITH NORECOVERY;';
    IF @Verbose = 1 RAISERROR(N'-- RESTORE LOG  ($(WL_Label)): %s', 0, 1, @restoreLog) WITH NOWAIT;
    EXEC(@restoreLog);

    FETCH NEXT FROM cur INTO @db;
END
CLOSE cur; DEALLOCATE cur;
"

--------------------------------------------------------------------------------
-- Macro: ADD DBs to AG if local is PRIMARY (run on both possible primaries)
--------------------------------------------------------------------------------
:setvar DoAgAddIfPrimary "
IF EXISTS (
    SELECT 1
    FROM sys.availability_groups ag
    JOIN sys.dm_hadr_availability_replica_states rs
         ON ag.group_id = rs.group_id AND rs.is_local = 1
    WHERE ag.name = @AGName AND rs.role_desc = 'PRIMARY'
)
BEGIN
    DECLARE @db sysname;
    DECLARE curAdd CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM #DBs ORDER BY name;
    OPEN curAdd;
    FETCH NEXT FROM curAdd INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (
            SELECT 1
            FROM sys.availability_databases_cluster adc
            JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
            WHERE ag.name = @AGName AND adc.database_name = @db
        )
        AND EXISTS (SELECT 1 FROM sys.databases WHERE name=@db AND state_desc='ONLINE')
        BEGIN
            DECLARE @sqlAdd NVARCHAR(MAX) =
                N'ALTER AVAILABILITY GROUP ' + QUOTENAME(@AGName) +
                N' ADD DATABASE ' + QUOTENAME(@db) + N';';
            IF @Verbose = 1 RAISERROR(N'-- ADD DB TO AG ($(WL_Label)) on %s: %s', 0, 1, @@SERVERNAME, @sqlAdd) WITH NOWAIT;
            EXEC(@sqlAdd);
        END
        FETCH NEXT FROM curAdd INTO @db;
    END
    CLOSE curAdd; DEALLOCATE curAdd;
END
"

--------------------------------------------------------------------------------
-- Macro: JOIN DBs on target (wait for cluster registration)
--------------------------------------------------------------------------------
:setvar DoAgJoinOnTarget "
DECLARE @dbJ sysname;
DECLARE curJoin CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM #DBs ORDER BY name;
OPEN curJoin;
FETCH NEXT FROM curJoin INTO @dbJ;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name=@dbJ AND state_desc='RESTORING')
    BEGIN
        DECLARE @elapsed INT = 0;
        WHILE @elapsed < ISNULL(@WaitSecs, 30)
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM sys.availability_databases_cluster adc
                JOIN sys.availability_groups ag ON adc.group_id = ag.group_id
                WHERE ag.name = @AGName AND adc.database_name = @dbJ
            )
            BEGIN
                DECLARE @sqlJoin NVARCHAR(4000) =
                    N'ALTER DATABASE ' + QUOTENAME(@dbJ) + N' SET HADR AVAILABILITY GROUP = ' + QUOTENAME(@AGName) + N';';
                IF @Verbose = 1 RAISERROR(N'-- JOIN ($(WL_Label)) on %s: %s', 0, 1, @@SERVERNAME, @sqlJoin) WITH NOWAIT;
                EXEC(@sqlJoin);
                BREAK;
            END
            WAITFOR DELAY '00:00:01';
            SET @elapsed += 1;
        END

        IF @elapsed >= ISNULL(@WaitSecs,30)
        BEGIN
            DECLARE @ErrJoinTimeout NVARCHAR(4000) =
                N'JOIN timeout on ' + @@SERVERNAME + N' for ' + QUOTENAME(@dbJ) +
                N': DB not yet registered in AG ' + QUOTENAME(@AGName) + N'.';
            THROW 51070, @ErrJoinTimeout, 1;
        END
    END
    FETCH NEXT FROM curJoin INTO @dbJ;
END
CLOSE curJoin; DEALLOCATE curJoin;
"

--------------------------------------------------------------------------------
-- Helper macro: run one workload (Backup + Restore) by WL#
-- (SQLCMD can't parameterize :CONNECT, so we just repeat blocks per WL)
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- WORKLOAD 1: Backup + Restore
--------------------------------------------------------------------------------
:setvar WL_Label "$(WL1_Label)"

:CONNECT $(WL1_Src)
DECLARE @DBList NVARCHAR(MAX)       = N'$(WL1_DBList)';
DECLARE @BackupShare NVARCHAR(4000) = N'$(BackupShare)';
DECLARE @Verbose INT                = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoBackupOnSource)
GO

:CONNECT $(WL1_Tgt)
DECLARE @DBList NVARCHAR(MAX)        = N'$(WL1_DBList)';
DECLARE @BackupShare NVARCHAR(4000)  = N'$(BackupShare)';
DECLARE @AGName sysname              = N'$(WL1_AG)';
DECLARE @CertName sysname            = NULLIF(N'$(CertName)', N'');
DECLARE @Verbose INT                 = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @Overwrite INT               = TRY_CONVERT(INT, '$(OverwriteIfExists)');
$(MakeDbList)
$(DoRestoreOnTarget)
GO

--------------------------------------------------------------------------------
-- WORKLOAD 2: Backup + Restore
--------------------------------------------------------------------------------
:setvar WL_Label "$(WL2_Label)"

:CONNECT $(WL2_Src)
DECLARE @DBList NVARCHAR(MAX)       = N'$(WL2_DBList)';
DECLARE @BackupShare NVARCHAR(4000) = N'$(BackupShare)';
DECLARE @Verbose INT                = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoBackupOnSource)
GO

:CONNECT $(WL2_Tgt)
DECLARE @DBList NVARCHAR(MAX)        = N'$(WL2_DBList)';
DECLARE @BackupShare NVARCHAR(4000)  = N'$(BackupShare)';
DECLARE @AGName sysname              = N'$(WL2_AG)';
DECLARE @CertName sysname            = NULLIF(N'$(CertName)', N'');
DECLARE @Verbose INT                 = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @Overwrite INT               = TRY_CONVERT(INT, '$(OverwriteIfExists)');
$(MakeDbList)
$(DoRestoreOnTarget)
GO

--------------------------------------------------------------------------------
-- WORKLOAD 3: Backup + Restore
--------------------------------------------------------------------------------
:setvar WL_Label "$(WL3_Label)"

:CONNECT $(WL3_Src)
DECLARE @DBList NVARCHAR(MAX)       = N'$(WL3_DBList)';
DECLARE @BackupShare NVARCHAR(4000) = N'$(BackupShare)';
DECLARE @Verbose INT                = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoBackupOnSource)
GO

:CONNECT $(WL3_Tgt)
DECLARE @DBList NVARCHAR(MAX)        = N'$(WL3_DBList)';
DECLARE @BackupShare NVARCHAR(4000)  = N'$(BackupShare)';
DECLARE @AGName sysname              = N'$(WL3_AG)';
DECLARE @CertName sysname            = NULLIF(N'$(CertName)', N'');
DECLARE @Verbose INT                 = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @Overwrite INT               = TRY_CONVERT(INT, '$(OverwriteIfExists)');
$(MakeDbList)
$(DoRestoreOnTarget)
GO

--------------------------------------------------------------------------------
-- POST-RESTORE AG: For each workload
-- 1) Try ADD on both possible primaries (Src + Tgt)
-- 2) JOIN on target
--------------------------------------------------------------------------------

-- Workload 1 post steps
:setvar WL_Label "$(WL1_Label)"

:CONNECT $(WL1_Src)
DECLARE @DBList NVARCHAR(MAX) = N'$(WL1_DBList)';
DECLARE @AGName sysname       = N'$(WL1_AG)';
DECLARE @Verbose INT          = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoAgAddIfPrimary)
GO

:CONNECT $(WL1_Tgt)
DECLARE @DBList NVARCHAR(MAX)  = N'$(WL1_DBList)';
DECLARE @AGName sysname        = N'$(WL1_AG)';
DECLARE @Verbose INT           = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @WaitSecs INT          = TRY_CONVERT(INT, '$(AddJoinWaitSeconds)');
$(MakeDbList)
$(DoAgAddIfPrimary)
$(DoAgJoinOnTarget)
GO

-- Workload 2 post steps
:setvar WL_Label "$(WL2_Label)"

:CONNECT $(WL2_Src)
DECLARE @DBList NVARCHAR(MAX) = N'$(WL2_DBList)';
DECLARE @AGName sysname       = N'$(WL2_AG)';
DECLARE @Verbose INT          = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoAgAddIfPrimary)
GO

:CONNECT $(WL2_Tgt)
DECLARE @DBList NVARCHAR(MAX)  = N'$(WL2_DBList)';
DECLARE @AGName sysname        = N'$(WL2_AG)';
DECLARE @Verbose INT           = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @WaitSecs INT          = TRY_CONVERT(INT, '$(AddJoinWaitSeconds)');
$(MakeDbList)
$(DoAgAddIfPrimary)
$(DoAgJoinOnTarget)
GO

-- Workload 3 post steps
:setvar WL_Label "$(WL3_Label)"

:CONNECT $(WL3_Src)
DECLARE @DBList NVARCHAR(MAX) = N'$(WL3_DBList)';
DECLARE @AGName sysname       = N'$(WL3_AG)';
DECLARE @Verbose INT          = TRY_CONVERT(INT, '$(Verbose)');
$(MakeDbList)
$(DoAgAddIfPrimary)
GO

:CONNECT $(WL3_Tgt)
DECLARE @DBList NVARCHAR(MAX)  = N'$(WL3_DBList)';
DECLARE @AGName sysname        = N'$(WL3_AG)';
DECLARE @Verbose INT           = TRY_CONVERT(INT, '$(Verbose)');
DECLARE @WaitSecs INT          = TRY_CONVERT(INT, '$(AddJoinWaitSeconds)');
$(MakeDbList)
$(DoAgAddIfPrimary)
$(DoAgJoinOnTarget)
GO
