SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_dynamic_snapshot_location]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_dynamic_snapshot_location] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_dynamic_snapshot_location]
	@pubid [uniqueidentifier],
	@partition_id [int],
	@dynsnap_location [nvarchar](255) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    declare @when_created datetime, @when_started datetime
    declare @cutoffdate datetime
    declare @curdate datetime
   
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid
    if @retcode<>0 or @@ERROR<>0
        return 1
        
    select @dynsnap_location = dynamic_snapshot_location, @when_created = last_updated, @when_started = last_started
        from dbo.MSmerge_dynamic_snapshots where partition_id = @partition_id	
    if @dynsnap_location is NULL
        return 0

    -- make sure that the dynamic snapshot was created within retention period
    select @curdate = getdate()
    select @cutoffdate = min(sys.fn_subtract_units_from_date(isnull(retention,0), retention_period_unit, @curdate))
        from dbo.sysmergepublications where pubid=@pubid

    if @when_created < @cutoffdate
    begin
        select @dynsnap_location = NULL

        -- clear out the old dynamic snapshot
        update dbo.MSmerge_dynamic_snapshots
            set dynamic_snapshot_location = NULL, last_updated = NULL, last_started = NULL
            where partition_id = @partition_id
    end
    
    -- for sub-based articles, make sure there is no generation interesting to this partition id that might have
    -- a coldate higher than this dynamic snapshot's start time. we really needed to care about remote generations only, but
    -- due to localization, even remote generations could end up looking like local. so, to be safe, look at all generations.
    if exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid and partition_options = 3)
    begin
		if @when_started is null or
			exists (select * from dbo.MSmerge_genhistory gh join dbo.MSmerge_generation_partition_mappings gpm
					on gh.generation = gpm.generation
					and (gh.art_nick = 0 or gh.art_nick in (select nickname from dbo.sysmergepartitioninfoview where partition_options = 3 and pubid = @pubid))
					and gh.coldate >= @when_started
					and (gpm.partition_id = @partition_id or gpm.partition_id = -1))
		begin
			select @dynsnap_location = NULL

			-- clear out the old dynamic snapshot
			update dbo.MSmerge_dynamic_snapshots
				set dynamic_snapshot_location = NULL, last_updated = NULL, last_started = NULL
				where partition_id = @partition_id
		end
    end
    
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_dynamic_snapshot_location] TO [public] AS [dbo]
GO
