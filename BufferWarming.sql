-- https://www.sqlshack.com/insight-into-the-sql-server-buffer-cache/
-- getting the top tables needed
SELECT COUNT(*)AS cached_pages_count   
    ,name ,index_id   
FROM sys.dm_os_buffer_descriptors AS bd   
    INNER JOIN   
    (  
        SELECT object_name(object_id) AS name   
            ,index_id ,allocation_unit_id  
        FROM sys.allocation_units AS au  
            INNER JOIN sys.partitions AS p   
                ON au.container_id = p.hobt_id   
                    AND (au.type = 1 OR au.type = 3)  
        UNION ALL  
        SELECT object_name(object_id) AS name     
            ,index_id, allocation_unit_id  
        FROM sys.allocation_units AS au  
            INNER JOIN sys.partitions AS p   
                ON au.container_id = p.partition_id   
                    AND au.type = 2  
    ) AS obj   
        ON bd.allocation_unit_id = obj.allocation_unit_id  
WHERE database_id = DB_ID()  
GROUP BY name, index_id   
ORDER BY cached_pages_count DESC;


-- checking the current state of buffer cache
SELECT
physical_memory_kb,
virtual_memory_kb,
committed_kb,
committed_target_kb
FROM sys.dm_os_sys_info;

-- Objects(Tables and Non-clusterd index) and its memory hogs currently in the buffer
-- Indexed views will be included as their indexes are distint entities from the tables they are derived from 
SELECT
objects.name AS object_name,
objects.type_desc AS object_type_description,
COUNT(*) AS buffer_cache_pages,
COUNT(*) * 8 / 1024  AS buffer_cache_used_MB
FROM sys.dm_os_buffer_descriptors
INNER JOIN sys.allocation_units
ON allocation_units.allocation_unit_id = dm_os_buffer_descriptors.allocation_unit_id
INNER JOIN sys.partitions
ON ((allocation_units.container_id = partitions.hobt_id AND type IN (1,3))
OR (allocation_units.container_id = partitions.partition_id AND type IN (2)))
INNER JOIN sys.objects
ON partitions.object_id = objects.object_id
WHERE allocation_units.type IN (1,2,3)
AND objects.is_ms_shipped = 0
AND dm_os_buffer_descriptors.database_id = DB_ID()
GROUP BY objects.name,
objects.type_desc
ORDER BY COUNT(*) DESC;

--- split out data by index, instead of table providing even further granularity on buffer cache usage 

sys.dm_os_buffer_descriptors: 
-	Determine the distribution of data pages in the buffer pool according to database, object or type
-	When a data page is read from disk, the page is copied into the SQL Server buffer pool and cached for reuse
-	Return cached pages for all user and system databases
Data: 
allocation_unit_id: ID of the allocation unit of the page. This value can be used to join sys.allocation_units. Is nullable.
read_microsec: The actual time (in microseconds) required to read the page into the buffer. This number is reset when the buffer is reused. Is nullable.
Find out: Count number of cached page 


agent jobs on a 2am 
first thing: 
whether the server is primary or not ?
	whether the instance has been restart or not in 24hours 
-> if yes then run the commands 

query command on the database show which table is using up most of memory - but it need to scan the table to query( Should not be run in business tables) 
-> figure out which tables 
-> should be after restarted (pointless) 
select big count - use top 5 


questions:
1.	How to proper load the table into buffer ?
2.	How to load the table into buffer without causing high load and blocking or wait event ? Resource Governance ? No Lock ? Indexing ? Prio adjustment ? Prevent CPU throttling ? Primary key ?
3.	Checking the current total memory the table is being load into the server atm. (time range for data for the past 1 week maybe ?)
a.	Go/No Go decision matrix
i.	Table size is less than 10% to 15% of your total buffer pool – Green (Can go batched memory warming)
ii.	Table size is from 20% to 40% of buffer pool – Yellow (Run script slowly)
iii.	Table size is > 50% - Red (Do not warm the whole table -> change to warming the index)
4.	Non-cluster index instead of the cluster index ?
5.	How to prevent page life expectancy plummet – measure how long the data page stays in memory before it’s kicked out 
6.	Should it be after every restart or only in maintenance mode to prevent unwanted incident ?
2. How to know whether the table has been successfully load to buffer ?
3. Monitoring and metric best suit ?

--- Begining for script

-- Make sqlcmd/SSMS stop on the first T-SQL error we THROW
-- Table Hint -> https://learn.microsoft.com/en-us/sql/t-sql/queries/hints-transact-sql-table?view=sql-server-ver17


/*
Buffer warming technique

Using index ID 0 (Heap) or 1 (Cluster Index) and NOLOCK to force the server to read the 
actual data page into buffer pool
Assign COUNT_BIG(*) 0 to prevent data is sent to the network

Prio-check 
- Size limit check - Should not load the whole table 
- Current PLE check - whether the servre is under memory pressure  
- Already Warmed check - If the buffer is already warm this should be skipped to prevent creating more load
*/

:ON ERROR EXIT
SET NOCOUNT ON;

-- list of tables need to be warm
DECLARE @AcurityTables TABLE (
    TableName NVARCHAR(128)
);

INSERT @AcurityTables (TableName)
VALUES
    ('General_Ledger'),
    ('Transaction_History'),
    ('Transaction_Lines'),
    ('Unpost_Gen_Ledger'),
    ('Tran_04_History'),
    ('Share_Certificate'),
    ('Batches_Processed');


-- check to see whether the server is Primary or Not 
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

-- Check is see whether the sql server has been restarted on not in 24hours 
DECLARE @IsRestartedIn24Hours BIT = 
    (
        SELECT CASE WHEN EXISTS (
            SELECT 1 
            FROM sys.dm_os_sys_info
            WHERE sqlserver_start_time >= DATEADD(HOUR, -24, GETDATE())
        ) THEN 1 ELSE 0 END
    ) 

IF @IsDbJoinedLocally = 1 AND @IsRestartedIn24Hours = 1
BEGIN
    PRINT 'Database is primary and has been restarted in the last 24hours'
    DECLARE cur_Warming CURSOR LOCAL FAST_FORWARD FOR
        SELECT 
            at.TableName, 
            i.index_id
        FROM @AcurityTables at
        JOIN sys.tables t ON at.TableName = t.name
        JOIN sys.indexes i ON t.object_id = i.object_id
        WHERE i.type IN (0, 1); -- Only get the base table data pages

    OPEN cur_Warming;
    FETCH NEXT FROM cur_Warming INTO @TableName, @IndexId;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- 3. Build the dynamic SQL
        -- DECLARE @Dummy prevents data from being sent to the SSMS grid.
        -- WITH (NOLOCK) prevents blocking active users while warming.
        -- INDEX(@IndexId) forces it to read the actual table data, not a tiny non-clustered index.

        SET @Sql = N'DECLARE @Dummy BIGINT; ' + 
                   N'SELECT @Dummy = COUNT_BIG(*) ' + 
                   N'FROM [' + @TableName + '] WITH (NOLOCK, INDEX(' + CAST(@IndexId AS NVARCHAR) + '));';

        PRINT 'Warming Table: ' + @TableName + ' (Reading Base Data Pages...)';

        -- 4. Execute the read
        EXEC sp_executesql @Sql;

        FETCH NEXT FROM cur_Warming INTO @TableName, @IndexId;
    END

    CLOSE cur_Warming;
    DEALLOCATE cur_Warming;

    PRINT 'Buffer warming completed safely.';
END


---
/*
Warming data for the last 7 days by 'Math Estimation' and 'Key Lookups'

1. Calculate Average Row Size: Get the total size of the table and divide by total rows to get the Average Bytes Per Row.

2. Count Recent Rows: Run a lightning-fast COUNT(*) on the last 7 days (using a Non-Clustered Index). Multiply that by the Average Row Size to estimate the Subset Size in MB.

3. Force a Key Lookup: We remove the INDEX(1) hint. Instead, we select a random, non-indexed column. This forces SQL Server to seek the dates in the small index, and then do a Key Lookup to drag only those specific data pages into the Buffer Pool.

*/

    DECLARE @MaxTableSizeMB INT = 10000; -- Max size we are willing to put in RAM (10 GB)
    DECLARE @DaysToWarm INT = -7;        -- Last 7 days
    DECLARE @TargetDate DATETIME = DATEADD(DAY, @DaysToWarm, GETDATE());

    -- We now need to map the Table Name to its Date Column!
    DECLARE @HotTables TABLE (
        PriorityID INT IDENTITY(1,1), 
        TableName NVARCHAR(128),
        DateColumnName NVARCHAR(128)
    );

    INSERT INTO @HotTables (TableName, DateColumnName)
    VALUES 
        ('Transaction_History', 'TransactionDate'), 
        ('Transaction_Lines',   'CreatedOn'),
        ('Batches_Processed',   'BatchDate');

    -- =========================================================================
    -- SCRIPT LOGIC
    -- =========================================================================
    DECLARE @TableName NVARCHAR(128), @DateCol NVARCHAR(128), @PayloadCol NVARCHAR(128);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @TotalRows BIGINT, @TotalMB BIGINT;
    DECLARE @RecentRows BIGINT, @EstimatedSubsetMB BIGINT;

    DECLARE cur_Warming CURSOR LOCAL FAST_FORWARD FOR 
        SELECT TableName, DateColumnName 
        FROM @HotTables ORDER BY PriorityID ASC;

    OPEN cur_Warming;
    FETCH NEXT FROM cur_Warming INTO @TableName, @DateCol;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '--------------------------------------------------------------'
        PRINT 'Analyzing: [' + @TableName + '] for dates >= ' + CONVERT(VARCHAR, @TargetDate, 120)
  
    -- 1. Get TOTAL Rows and TOTAL Size to calculate Average Row Size
    SELECT 
        @TotalRows = ISNULL(SUM(rows), 1), -- default to 1 to prevent divide by zero
        @TotalMB = ISNULL(SUM(used_page_count) * 8 / 1024, 0)
    FROM sys.dm_db_partition_stats
    WHERE object_id = OBJECT_ID(@TableName) AND index_id IN (0, 1);

    -- 2. Count how many rows exist in the last 7 days
    SET @Sql = N'SELECT @CountOUT = COUNT(*) FROM [' + @TableName + '] (NOLOCK) WHERE [' + @DateCol + '] >= @TDate';
    EXEC sp_executesql @Sql, N'@TDate DATETIME, @CountOUT BIGINT OUTPUT', @TargetDate, @RecentRows OUTPUT;

    -- 3. MATH: Estimate the size of the 7-day subset
    -- (TotalMB / TotalRows) = Avg MB per row. Multiplied by RecentRows.
    SET @EstimatedSubsetMB = (@TotalMB * 1.0 / NULLIF(@TotalRows, 0)) * @RecentRows;

    PRINT '   Total Table Size: ' + CAST(@TotalMB AS NVARCHAR) + ' MB (' + CAST(@TotalRows AS NVARCHAR) + ' rows)'
    PRINT '   7-Day Subset Size: ' + CAST(@EstimatedSubsetMB AS NVARCHAR) + ' MB (' + CAST(@RecentRows AS NVARCHAR) + ' rows)'

    -- 4. PRIORITY/SAFETY CHECK
    IF @EstimatedSubsetMB > @MaxTableSizeMB
    BEGIN
        PRINT '   >> SKIPPED: The 7-day subset exceeds the safety limit of ' + CAST(@MaxTableSizeMB AS NVARCHAR) + ' MB.'
    END
    ELSE IF @RecentRows = 0
    BEGIN
        PRINT '   >> SKIPPED: No data found in the last ' + CAST(ABS(@DaysToWarm) AS NVARCHAR) + ' days.'
    END
    ELSE
    BEGIN
        PRINT '   >> WARMING: Loading 7-day subset into Buffer...'
        
        -- 5. THE TRICK: Dynamically grab a column that is NOT the date column.
        -- Selecting a column not in the date index forces SQL to read the base data page (Key Lookup)
        SELECT TOP 1 @PayloadCol = name 
        FROM sys.columns 
        WHERE object_id = OBJECT_ID(@TableName) AND name <> @DateCol;

        -- We do NOT use INDEX(1) here. We let the optimizer use the Date index, 
        -- but force it to pull @PayloadCol out of the base table.
        SET @Sql = N'DECLARE @Dummy BIGINT; ' + 
                   N'SELECT @Dummy = COUNT_BIG([' + @PayloadCol + ']) ' + 
                   N'FROM [' + @TableName + '] WITH (NOLOCK) ' + 
                   N'WHERE [' + @DateCol + '] >= @TDate;';
        
        EXEC sp_executesql @Sql, N'@TDate DATETIME', @TargetDate;
        PRINT '   >> Completed.'
    END





