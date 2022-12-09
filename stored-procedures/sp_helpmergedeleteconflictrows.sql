SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergedeleteconflictrows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergedeleteconflictrows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergedeleteconflictrows]
	@publication [sysname],
	@source_object [nvarchar](386),
	@publisher [sysname],
	@publisher_db [sysname],
	@logical_record_conflicts [int]
WITH EXECUTE AS CALLER
AS
declare @pubid			uniqueidentifier
	declare @cmd			nvarchar(4000)	
	declare @pubidstr		nvarchar(38)
	declare @retcode		int

	-- Security check: dbo and sysadmin only
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end	   

	if @publisher IS NULL
		select @publisher = publishingservername()
		
	if @publisher_db IS NULL
		select @publisher_db = db_name()
	select @cmd = 'select distinct source_object = schema_name(sys.objects.schema_id) + '
	select @cmd = @cmd + '''.'''
	select @cmd = @cmd + ' + sys.objects.name, MSmerge_conflicts_info.rowguid, MSmerge_conflicts_info.conflict_type, '
	select @cmd = @cmd + ' MSmerge_conflicts_info.reason_code, MSmerge_conflicts_info.reason_text, '
	select @cmd = @cmd + ' MSmerge_conflicts_info.origin_datasource, MSmerge_conflicts_info.pubid, MSmerge_conflicts_info.MSrepl_create_time from MSmerge_conflicts_info, dbo.sysmergearticles, sys.objects'	 
	select @cmd = @cmd + ' where dbo.sysmergearticles.nickname = MSmerge_conflicts_info.tablenick 
					 and sys.objects.object_id = dbo.sysmergearticles.objid '

    -- Do not return logical record conflicts unless requested.
	if @logical_record_conflicts = 0
	begin
        select @cmd = @cmd + ' and MSmerge_conflicts_info.conflict_type in (4, 7, 8) '
	end
	else
	begin
        select @cmd = @cmd + ' and MSmerge_conflicts_info.conflict_type in (4, 7, 8, 12) '
	end
	
	if @publication <> '%'
		begin
			/*
			** Parameter Check:	 @publication.
			** Make sure that the publication exists.
			*/
			select @pubid = pubid from dbo.sysmergepublications 
				where name = @publication and 
					LOWER(publisher) = LOWER(@publisher) and
					publisher_db = @publisher_db
			if @pubid IS NULL
				BEGIN
					RAISERROR (20026, 16, -1, @publication)
					RETURN (1)
				END
			set @pubidstr = '''' + convert(nchar(36), @pubid) + '''' 
			select @cmd = @cmd + ' and MSmerge_conflicts_info.pubid = ' + @pubidstr
		end

	if @source_object IS NOT NULL
		begin
			declare @object			sysname	 
			declare @owner			sysname	 
			declare @tablenick		int
			declare @tablenickstr	nvarchar(11)
			
			select @object = PARSENAME(@source_object, 1)
			select @owner = PARSENAME(@source_object, 2)
			execute sys.sp_MStablenickname @owner, @object, @tablenick output
			if @tablenick IS NULL
				BEGIN
					raiserror (20003, 11, -1, @object)
					RETURN (1)
				END
			set @tablenickstr = convert(nchar, @tablenick)
			select @cmd = @cmd + ' and MSmerge_conflicts_info.tablenick = '
			select @cmd = @cmd + @tablenickstr
		end

	exec (@cmd)
	if (@@error <> 0)
		RETURN (1)
	
	return 0
GO
GRANT EXECUTE ON [sys].[sp_helpmergedeleteconflictrows] TO [public] AS [dbo]
GO
