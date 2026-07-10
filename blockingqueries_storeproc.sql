DROP TABLE IF EXISTS #Who2;
 
CREATE TABLE #Who2 (
    SPID INT,
    Status VARCHAR(50),
    Login VARCHAR(100),
    HostName VARCHAR(100),
    BlkBy VARCHAR(10),
    DBName VARCHAR(100),
    Command VARCHAR(100),
    CPUTime INT,
    DiskIO INT,
    LastBatch VARCHAR(100),
    ProgramName VARCHAR(255),
    SPID2 INT,
    RequestID INT
);
 
INSERT INTO #Who2
EXEC sp_who2;
 
;WITH Blocked AS
(
    SELECT
        'Blocked Session' AS RowType,
        w.SPID,
        TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(w.BlkBy)), '.')) AS RelatedSPID,
        w.Status,
        w.Login,
        w.HostName,
        w.BlkBy,
        w.DBName,
        w.Command,
        w.CPUTime,
        w.DiskIO,
        w.LastBatch,
        w.ProgramName,
        r.status AS RequestStatus,
        r.command AS RequestCommand,
        r.wait_type,
        r.wait_time,
        r.blocking_session_id,
        SUBSTRING
        (
            st.text,
            (r.statement_start_offset / 2) + 1,
            (
                (
                    CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE r.statement_end_offset
                    END
                    - r.statement_start_offset
                ) / 2
            ) + 1
        ) AS CurrentStatement,
        st.text AS FullBatch
    FROM #Who2 w
    LEFT JOIN sys.dm_exec_requests r
        ON w.SPID = r.session_id
    LEFT JOIN sys.dm_exec_connections c
        ON w.SPID = c.session_id
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) st
    WHERE TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(w.BlkBy)), '.')) IS NOT NULL
),
Blocking AS
(
    SELECT
        'Blocking Session' AS RowType,
        w2.SPID,
        b.SPID AS RelatedSPID,
        w2.Status,
        w2.Login,
        w2.HostName,
        w2.BlkBy,
        w2.DBName,
        w2.Command,
        w2.CPUTime,
        w2.DiskIO,
        w2.LastBatch,
        w2.ProgramName,
        r.status AS RequestStatus,
        r.command AS RequestCommand,
        r.wait_type,
        r.wait_time,
        r.blocking_session_id,
        SUBSTRING
        (
            st.text,
            (r.statement_start_offset / 2) + 1,
            (
                (
                    CASE r.statement_end_offset
                        WHEN -1 THEN DATALENGTH(st.text)
                        ELSE r.statement_end_offset
                    END
                    - r.statement_start_offset
                ) / 2
            ) + 1
        ) AS CurrentStatement,
        st.text AS FullBatch
    FROM Blocked b
    JOIN #Who2 w2
        ON w2.SPID = b.RelatedSPID
    LEFT JOIN sys.dm_exec_requests r
        ON w2.SPID = r.session_id
    LEFT JOIN sys.dm_exec_connections c
        ON w2.SPID = c.session_id
    OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) st
)
SELECT *
FROM Blocked
 
UNION ALL
 
SELECT *
FROM Blocking
 
ORDER BY RelatedSPID
    , 1
    , SPID;
 
DROP TABLE #Who2;
