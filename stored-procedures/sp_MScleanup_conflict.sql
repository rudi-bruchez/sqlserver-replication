SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanup_conflict]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanup_conflict] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanup_conflict]
	@pubid [uniqueidentifier],
	@conflict_retention [int]
WITH EXECUTE AS CALLER
AS
declare @pubname			sysname
	declare @valid_date			datetime
	declare @conflict_table		nvarchar(512)
	declare @conflict_id		int
	declare @retention_string		nvarchar(100)
	declare @pubidstr			nvarchar(100)
	declare @retcode			int
	
	--if no conflict_retention value is specified, query local table and find out.
	if @conflict_retention is NULL
		select @conflict_retention=conflict_retention from dbo.sysmergepublications where pubid=@pubid

	--do not do any cleanup if conflict retention value is 0
	else if @conflict_retention = 0
		return (0)

	select @pubname=name from dbo.sysmergepublications where pubid=@pubid
	select @pubidstr = convert(nvarchar(40), @pubid)
	select @valid_date = dateadd(day, -@conflict_retention, getdate())
	select @retention_string = convert(nvarchar, @conflict_retention)
	/*
	** Security Check
	*/
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
        	return (1)
	
	declare AC CURSOR LOCAL FAST_FORWARD for select conflict_table from dbo.sysmergearticles where pubid=@pubid
	open AC
	fetch AC into @conflict_table
	while (@@fetch_status<>-1)
	begin
		if @conflict_table is NOT null
			begin

			select @conflict_id = object_id(@conflict_table)
			select @conflict_table=QUOTENAME(@conflict_table)

			if @conflict_id is not NULL and @retention_string is not NULL 
					begin
						exec ('delete from ' + @conflict_table + ' from ' + @conflict_table + ' ct , MSmerge_conflicts_info info where 
							ct.rowguidcol = info.rowguid and ct.origin_datasource_id=info.origin_datasource_id and 
							datediff(dd, info.MSrepl_create_time, getdate()) > ' + @retention_string 
							+ ' and info.pubid = ''' + @pubidstr + '''')
						if @@ERROR<>0
							goto FAILURE
						exec ('delete from MSmerge_conflicts_info where datediff(dd, MSrepl_create_time, getdate()) > ' + @retention_string 
							+ ' and pubid = ''' + @pubidstr + '''')
						if @@ERROR<>0
							goto FAILURE
					end
			end
		fetch next from AC into @conflict_table
	end
	close AC
	deallocate AC
	return (0)
FAILURE:
	close AC
	deallocate AC
	raiserror(20709, 16, -1, @conflict_table, @pubname);
	return (1)
GO
GRANT EXECUTE ON [sys].[sp_MScleanup_conflict] TO [public] AS [dbo]
GO
