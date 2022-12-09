SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergearticleconflicts]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergearticleconflicts] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergearticleconflicts]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
	declare @pubid			uniqueidentifier
	declare @cmd			nvarchar(4000)

	declare @retcode		int
	declare @nickname		int
	declare @retcode2		int
	declare @name			sysname
	declare @source_owner	sysname
	declare @source_object	sysname
	declare @conflict_table sysname
	declare @guidcolname		sysname
	declare @centralized_conflicts int
	declare @objid			int
	declare @command		nvarchar(2000)	 
	
	-- Security check: dbo and sysadmin only
	select @retcode = 0
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end

	if @publisher IS NULL
		select @publisher = publishingservername()
		
	if @publisher_db IS NULL
		select @publisher_db = db_name()

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
		end

	create table #temp_conflict(article					sysname collate database_default,
								source_owner			sysname collate database_default,
								source_object			sysname collate database_default,
								conflict_table			sysname collate database_default,
								guidcolname				sysname collate database_default,
								centralized_conflicts	int)	

	declare #cur_conflict cursor local for 
		select name, objid, conflict_table, pubid, nickname from dbo.sysmergearticles 
			where conflict_table is not NULL and pubid in (select pubid from dbo.sysmergepublications where name like @publication)
				for read only
	open #cur_conflict
	fetch #cur_conflict into @name, @objid, @conflict_table, @pubid, @nickname
	while (@@fetch_status <> -1)
	begin
		select @source_owner = SCHEMA_NAME(schema_id) from sys.objects where object_id = @objid
		select @source_object = object_name (@objid)
		select @guidcolname = name from sys.columns where object_id = @objid and is_rowguidcol = 1
		select @centralized_conflicts = centralized_conflicts from dbo.sysmergepublications where pubid = @pubid

		select @command = 'if exists (select * from ' + QUOTENAME(@conflict_table) + ') select @retcode2 = 1
								else select @retcode2 = 0'
		EXEC @retcode = sys.sp_executesql @command, N'@retcode2 int output', @retcode2 output
		if @retcode <>0
				return (1)
		if @retcode2 = 1 
		begin
			insert into #temp_conflict 
				values (@name, @source_owner, @source_object, @conflict_table, @guidcolname, @centralized_conflicts)
		end
		--return delete conflicts to be compatible with old conflict structure
		if EXISTS (select * from MSmerge_conflicts_info where tablenick = @nickname and conflict_type in (4,7,8,12))
		begin
			insert into #temp_conflict
				values (@name, @source_owner, @source_object, 'MSmerge_conflicts_info', @guidcolname, @centralized_conflicts)
		end
		fetch #cur_conflict into @name, @objid, @conflict_table, @pubid, @nickname
	end

	select * from #temp_conflict order by article, conflict_table

	drop table #temp_conflict
	close #cur_conflict
	deallocate #cur_conflict
return(0)		
GO
GRANT EXECUTE ON [sys].[sp_helpmergearticleconflicts] TO [public] AS [dbo]
GO
