-- get meaning usage statas of the Trans Tablle 

SELECT 
			OBJECT_NAME(s.[object_id]) as [Table],
            i.name,
            s.user_updates as TotalWrites,
            s.user_seeks + s.user_scans + s.user_lookups as TotalReads,
            s.user_updates - (s.user_seeks + s.user_scans + s.user_lookups) as Difference,
			(s.user_seeks + s.user_scans + s.user_lookups) / cast(s.user_updates as decimal(20,2)) * 100 as 'Difference %'
        FROM sys.dm_db_index_usage_stats AS s WITH (NOLOCK)
        INNER JOIN sys.indexes AS i WITH (NOLOCK)
            ON s.[object_id] = i.[object_id] AND i.index_id = s.index_id
        INNER JOIN sys.objects AS o WITH (NOLOCK)
            ON i.[object_id] = o.[object_id]
        WHERE OBJECTPROPERTY(s.[object_id], 'IsUserTable') = 1
        AND s.database_id = DB_ID()
		and OBJECT_NAME(s.[object_id]) = 'Trans'

-- => Comapare the total write and read of each Index -> Conclude with the total different %

-- Mising index assessment 
	SELECT 
        CONVERT(DECIMAL(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) as IndexAdvantage,
        'Trans' as statement,
        COUNT(1) OVER(PARTITION BY mid.[statement]) as MissingIndexesForTable,
        COUNT(1) OVER(PARTITION BY mid.[statement], mid.equality_columns) as SimilarMissingIndexesForTable,
        mid.equality_columns,
        mid.inequality_columns,
        mid.included_columns,
        migs.user_seeks,
        CONVERT(DECIMAL(18,2), migs.avg_total_user_cost) as AvgTotalUserCost,
        migs.avg_user_impact
    FROM sys.dm_db_missing_index_groups AS mig WITH (NOLOCK)
    INNER JOIN sys.dm_db_missing_index_group_stats_query AS migs WITH (NOLOCK)
        ON mig.index_group_handle = migs.group_handle
    CROSS APPLY sys.dm_exec_sql_text(migs.last_sql_handle) AS st
    INNER JOIN sys.dm_db_missing_index_details AS mid WITH (NOLOCK)
        ON mig.index_handle = mid.index_handle
	where OBJECT_NAME([object_id]) = 'Trans'
    ORDER BY 
        CONVERT(DECIMAL(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) DESC
