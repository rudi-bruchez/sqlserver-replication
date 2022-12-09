SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSvalidate_dest_recgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSvalidate_dest_recgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSvalidate_dest_recgen]
	@pubid [uniqueidentifier],
	@recguid [uniqueidentifier],
	@recgen [bigint]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int, @has_subbased bit, @has_downloadonly bit, @is_publisher bit, @min_sentgen bigint
	
	exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid=@pubid
    if @@error <> 0 or @retcode <> 0
		return 1
	
	select @has_subbased = 0, @has_downloadonly = 0, @is_publisher = 0
	
	exec @retcode = sys.sp_MSvalidatecommongen @commongen = @recgen, @commongenguid = @recguid
	if @@error <> 0 or @retcode <> 0
		return 1
	
	if exists (select distinct * from dbo.sysmergepartitioninfoview 
				where partition_options = 3
				and pubid = @pubid)
		select @has_subbased = 1
               
     if exists (select * from dbo.sysmergepartitioninfoview smpi1
					where (upload_options = 1 or upload_options = 2)
					and pubid = @pubid)
		select @has_downloadonly = 1
		
	if sys.fn_MSmerge_islocalpubid(@pubid) = 1
		select @is_publisher = 1
		
	if @is_publisher = 1
	begin
		if @has_subbased = 1 or @has_downloadonly = 1
		begin
			select @min_sentgen = isnull(min(sentgen),0) from dbo.sysmergesubscriptions
            where pubid = @pubid 
            and subid <> @pubid
            
            if @recgen < @min_sentgen
            begin
				RAISERROR(21800 , 16, -1)
				return 1
			end
		end
	end
	else
	begin
		if @has_subbased = 1
		begin
			select @min_sentgen = isnull(min(sentgen),0) from dbo.sysmergesubscriptions
            where pubid = @pubid 
            and subid = @pubid
            
            if @recgen < @min_sentgen
            begin
				RAISERROR(21800 , 16, -1)
				return 1
			end
		end
	end
	
	if exists (select * from dbo.sysmergepublications where isnull(retention,0) = 0)
        return 0
    
    declare @curdate datetime, @cutoffdate datetime
    
    select @curdate = getdate()
    
    select @cutoffdate = min(sys.fn_subtract_units_from_date(isnull(retention,0), retention_period_unit, @curdate))
    from dbo.sysmergepublications
		
	if @recgen = 0 or exists (select * from dbo.MSmerge_genhistory where generation = @recgen and coldate <= @cutoffdate)
	begin
		RAISERROR(21800 , 16, -1)
		return 1
	end
	
	return 0
	
end
GO
GRANT EXECUTE ON [sys].[sp_MSvalidate_dest_recgen] TO [public] AS [dbo]
GO
