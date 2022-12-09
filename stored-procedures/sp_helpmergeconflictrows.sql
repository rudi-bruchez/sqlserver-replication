SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergeconflictrows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergeconflictrows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergeconflictrows]
	@publication [sysname],
	@conflict_table [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@logical_record_conflicts [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @pubid          uniqueidentifier
    declare @cmd            nvarchar(max)  
    declare @colname		sysname
    declare @colid			int
    declare @pubidstr       nvarchar(38)
    declare @retcode        int
	declare @result_table	sysname
	declare @guid			uniqueidentifier

    -- Security check
    if 1 <> is_member('db_owner') and
	   (1 <> is_member('replmonitor') or is_member('replmonitor') is null)
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end

	declare @quotedcolname nvarchar(258)

    select @guid = newid()

    if @publisher IS NULL
    	select @publisher = publishingservername()
    	
    if @publisher_db IS NULL
	    select @publisher_db = db_name()

	select @colname=NULL
	
	select @colid = min(column_id) from sys.columns where object_id = object_id(@conflict_table)
	select @colname=name from sys.columns where object_id = object_id(@conflict_table) and column_id=@colid
	select @cmd = 'select '

	while (@colname is not NULL)
	begin
		if @colname <> 'origin_datasource_id'
		begin
			select @quotedcolname = quotename(@colname)
			select @cmd = @cmd + ' ct.' + @quotedcolname + ','	
		end
		select @colid = min(column_id) from sys.columns where object_id = object_id(@conflict_table) and column_id > @colid
		select @colname = NULL
		select @colname=name from sys.columns where object_id = object_id(@conflict_table) and column_id=@colid
	end
    select @cmd = @cmd + ' m.origin_datasource, m.conflict_type, m.reason_code, m.reason_text, m.pubid, m.MSrepl_create_time from' 
    select @cmd = @cmd + QUOTENAME(@conflict_table) + ' ct, MSmerge_conflicts_info m where ct.origin_datasource_id=m.origin_datasource_id
    			and m.conflict_type<>4 and ct.rowguidcol=m.rowguid '

    -- Do not return logical record conflicts unless specifically asked for
    if @logical_record_conflicts = 0
    begin
        select @cmd = @cmd + ' and m.conflict_type not in (11,12,13,14) '
    end
    
    if @publication <> '%'
    begin
        /*
        ** Parameter Check:  @publication.
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
        select @cmd = @cmd + ' and m.pubid = ' + @pubidstr
    end
    exec (@cmd)

    if (@@ERROR <> 0)
    	return (1)
   	return (0)
GO
GRANT EXECUTE ON [sys].[sp_helpmergeconflictrows] TO [public] AS [dbo]
GO
