SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpmergeconflictcounts]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpmergeconflictcounts] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpmergeconflictcounts]
	@publication_name [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@logical_record_conflicts [int]
WITH EXECUTE AS CALLER
AS
begin

	set nocount on 

	declare @aname		sysname
	declare @cmd		nvarchar(2000) 
	declare @conflict_table sysname 
	declare @count		integer
	declare @pubid		uniqueidentifier
	declare @pubidstr	nvarchar(38)
    declare @retcode	int

    -- Security check
    if 1 <> is_member('db_owner') and
	   (1 <> is_member('replmonitor') or is_member('replmonitor') is null)
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end

	if @publisher IS NULL
		select @publisher = publishingservername()
		
	if @publisher_db IS NULL
		select @publisher_db = db_name()

	if @publication_name <> '%'
		begin
			/*
			** Parameter Check:	 @publication.
			** Make sure that the publication exists.
			*/
			select @pubid = pubid from dbo.sysmergepublications 
				where name = @publication_name and 
					LOWER(publisher) = LOWER(@publisher) and
					publisher_db = @publisher_db
			if @pubid IS NULL
			BEGIN
				RAISERROR (20026, 16, -1, @publication_name)
				RETURN (1)
			END
			set @pubidstr = '''' + convert(nchar(36), @pubid) + '''' 
		end

	-- make sure current db has merge publishing tables (true on both pub and sub)
	if object_id('sysmergearticles') is NULL
	begin
		raiserror( 18757, 16, -1 )
		return(1)
	end

	-- allow null conflict table name to handle case where there are delete conflicts but no update conflicts
	create table #result_list ( article sysname collate database_default, source_object sysname collate database_default, conflict_table sysname collate database_default null, guidcolname sysname collate database_default, centralized_conflicts integer, conflicts_ucount integer, conflicts_dcount integer )
	create table #conflict_list ( article_name sysname collate database_default, conflicts_ucount integer, conflicts_dcount integer )
	create table #update_list ( article_name sysname collate database_default, conflicts_ucount integer )

	-- get delete counts
	if ( @publication_name = '%' )
		declare hCdcount CURSOR LOCAL FAST_FORWARD for 
			select distinct a.name 
				from dbo.MSmerge_conflicts_info d
				inner join dbo.sysmergepublications p on p.pubid = d.pubid
				inner join dbo.sysmergearticles a on a.pubid = p.pubid and a.nickname = d.tablenick
				where d.conflict_type in (4,7,8,12)
	else
		declare hCdcount CURSOR LOCAL FAST_FORWARD for 
			select distinct a.name 
				from dbo.MSmerge_conflicts_info d
				inner join dbo.sysmergepublications p on p.pubid = d.pubid
				inner join dbo.sysmergearticles a on a.pubid = p.pubid and a.nickname = d.tablenick
				where p.pubid = @pubid and d.conflict_type in (4,7,8,12)
	open hCdcount
	fetch hCdcount into @aname
	while ( @@fetch_status <> -1 )
	begin
		select @cmd = 'select N''' + @aname + ''', 0, count(*) 
				from dbo.MSmerge_conflicts_info d
					inner join dbo.sysmergepublications p on p.pubid = d.pubid
					inner join dbo.sysmergearticles a on a.pubid = p.pubid and a.nickname = d.tablenick '

		if @logical_record_conflicts = 0
		begin
			set @cmd = @cmd + 'where d.conflict_type in (4,7,8) and a.name = @aname'
		end
		else
		begin
			set @cmd = @cmd + 'where d.conflict_type in (4,7,8,12) and a.name = @aname'
		end

		if ( @publication_name <> '%' ) 
			select @cmd = @cmd + ' and p.pubid = ' + @pubidstr

		insert #conflict_list ( article_name, conflicts_ucount, conflicts_dcount )
			exec @retcode= dbo.sp_executesql @cmd, N'@aname sysname', @aname = @aname
		if @@error<>0 and @retcode<>0
		begin
			close hCdcount
			deallocate hCdcount
			return 1
		end

		fetch hCdcount into @aname
	end
	close hCdcount
	deallocate hCdcount

	-- get update counts
	if ( @publication_name = '%' )
		declare hCucount CURSOR LOCAL FAST_FORWARD for 
			select distinct a.name, a.conflict_table
				from dbo.sysmergepublications p
				inner join dbo.sysmergearticles a on a.pubid = p.pubid
			where a.conflict_table is not null
	else
		declare hCucount CURSOR LOCAL FAST_FORWARD for 
			select distinct a.name, a.conflict_table
				from dbo.sysmergepublications p
				inner join dbo.sysmergearticles a on a.pubid = p.pubid
			where a.conflict_table is not null
				and p.pubid = @pubid
	open hCucount
	fetch hCucount into @aname, @conflict_table
	while ( @@fetch_status <> -1 )
	begin
		select @cmd = N'select N''' + @aname + N''', count(*) from ' + QUOTENAME( @conflict_table ) + N' ct 
		inner join MSmerge_conflicts_info m on ct.origin_datasource_id=m.origin_datasource_id and ct.rowguidcol=m.rowguid
		inner join dbo.sysmergepublications p on p.pubid = m.pubid '

	    -- Do not return logical record conflicts unless asked for.
	    if @logical_record_conflicts = 0
	    begin
    		select @cmd = @cmd + '
    		where m.conflict_type not in (11,12,13,14) '

		if ( @publication_name <> '%' ) 
			select @cmd = @cmd + ' and p.name = @publication_name'
    		
	    end
	    else
	    begin
		if ( @publication_name <> '%' ) 
			select @cmd = @cmd + ' where p.name = @publication_name'
	    end
	    
		insert #update_list ( article_name, conflicts_ucount )
			exec @retcode= dbo.sp_executesql @cmd, N'@publication_name sysname', @publication_name = @publication_name
		if @@error<>0 and @retcode<>0
		begin
			close hCucount
			deallocate hCucount
			return 1
		end

		fetch hCucount into @aname, @conflict_table
	end
	close hCucount
	deallocate hCucount

	update #conflict_list set conflicts_ucount = isnull( ul.conflicts_ucount, 0 )
		from #conflict_list cl
		inner join #update_list ul on ul.article_name = cl.article_name

	delete #update_list 
		from #update_list ul 
		inner join #conflict_list cl on ul.article_name = cl.article_name

	insert #conflict_list
		select *, 0 from #update_list where conflicts_ucount > 0

	drop table #update_list
	select @cmd = N'insert into #result_list 
			select distinct t.article_name, N'''' + quotename(schema_name( o.schema_id )) + ''.'' + quotename(o.name) + '''',' + ' a.conflict_table, c.name, p.centralized_conflicts, t.conflicts_ucount, t.conflicts_dcount
				from #conflict_list t
					inner join dbo.sysmergearticles a on a.name = t.article_name
					inner join dbo.sysmergepublications p on p.pubid = a.pubid
					inner join sys.objects o on o.object_id = a.objid 
					inner join sys.columns c on c.object_id = o.object_id and c.is_rowguidcol = 1
				where (t.conflicts_ucount > 0 or t.conflicts_dcount > 0) and a.conflict_table is NOT NULL and p.name like @publication_name'

	exec @retcode= sys.sp_executesql @cmd, N'@publication_name sysname', @publication_name=@publication_name
	if @@error<>0 or @retcode<>0 return 1

	drop table #conflict_list

	select * from #result_list
	drop table #result_list

return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelpmergeconflictcounts] TO [public] AS [dbo]
GO
