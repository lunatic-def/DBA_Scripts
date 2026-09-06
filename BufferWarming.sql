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








General_Ledger
Transaction_History
Transaction_Lines
Unpost_Gen_Ledger
Tran_04_History
Share_Certificate
Batches_Processed



