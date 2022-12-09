SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_deletemergeconflictrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_deletemergeconflictrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_deletemergeconflictrow]
	@conflict_table [sysname],
	@source_object [nvarchar](386),
	@rowguid [uniqueidentifier],
	@origin_datasource [varchar](255),
	@drop_table_if_empty [varchar](10)
WITH EXECUTE AS CALLER
AS
declare @retcode		int
	declare @cmd			nvarchar(4000)	
	declare @rowguidstr		nvarchar(40)
	declare @object			sysname	 
	declare @owner			sysname	 
	declare @tablenick		int
	declare @tablenickstr	nvarchar(11)
	declare @escaped_origin_datasource varchar(511)

	-- Security check: dbo and sysadmin only
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end	   

	set @rowguidstr = convert(nchar(36), @rowguid)
	set @escaped_origin_datasource = replace(@origin_datasource, '''', '''''')

    /* Delete conflict from Conflict_<Table> */
    if @conflict_table <> '%'
        begin
            select @cmd = 'delete '
            select @cmd = @cmd + quotename(@conflict_table) 
            select @cmd = @cmd + ' from ' + quotename(@conflict_table) + ' ct , MSmerge_conflicts_info info '
            select @cmd = @cmd + ' where info.origin_datasource = '''
            select @cmd = @cmd + @escaped_origin_datasource 
            select @cmd = @cmd + ''' and ct.rowguidcol = '''
            select @cmd = @cmd + @rowguidstr
            select @cmd = @cmd + ''' and info.rowguidcol = '''
            select @cmd = @cmd + @rowguidstr
            select @cmd = @cmd + 'ct.origin_datasource_id=info.origin_datasource_id '          
            select @cmd = @cmd + ''''

            -- DEBUG select 'Delete conflict_table query' = @cmd
            exec (@cmd)
            if @@ERROR<>0 return (1)

            select @cmd = 'delete from MSmerge_conflicts_info where origin_datasource = ''' + @escaped_origin_datasource + '''
            					and rowguid = ''' + @rowguidstr + ''''
            exec (@cmd)
            if @@ERROR<>0 return (1)

            if LOWER(@drop_table_if_empty collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            begin
                select @cmd = 'if not exists (select 1 from ' 
                select @cmd = @cmd + quotename(@conflict_table) 
                select @cmd = @cmd + ')'
                select @cmd = @cmd + ' update dbo.sysmergearticles set ins_conflict_proc = NULL, conflict_table = NULL where conflict_table = ''' + quotename(@conflict_table) + ''''
                -- DEBUG select "Update conflict_table query" = @cmd
                exec (@cmd)
                if @@ERROR<>0 
                    return (1)
                
                select @cmd = 'if not exists (select 1 from ' 
                select @cmd = @cmd + quotename(@conflict_table)
                select @cmd = @cmd + ')'
                select @cmd = @cmd + ' drop table '
                select @cmd = @cmd + quotename(@conflict_table)
                select @cmd = @cmd + ''
                -- DEBUG select "Drop conflict_table query" = @cmd
                exec (@cmd)
                if @@ERROR<>0 return (1)
            end
        end
    /* Delete conflict from MSmerge_conflicts_info */
    else
        begin
        	if @source_object is NULL
        		begin
        			raiserror(14043, 16, -1, '@source_object', 'sp_deletemergeconflictrow')
        			return (1)
        		end
            select @object = PARSENAME(@source_object, 1)
            select @owner = PARSENAME(@source_object, 2)
            execute @retcode=sys.sp_MStablenickname @owner, @object, @tablenick output
        
            if @tablenick IS NULL or @@ERROR<>0 or @retcode<>0
                BEGIN
                    raiserror (20003, 11, -1, @object)
                    RETURN (1)
                END

			set @tablenickstr = convert(nchar, @tablenick)

			
			select @cmd = 'delete from MSmerge_conflicts_info'
			select @cmd = @cmd + ' where origin_datasource = '''
			select @cmd = @cmd + @escaped_origin_datasource 
			select @cmd = @cmd + ''' and tablenick = '
			select @cmd = @cmd + @tablenickstr
			select @cmd = @cmd + ' and rowguid = '''
			select @cmd = @cmd + @rowguidstr
			select @cmd = @cmd + ''''
			-- DEBUG select 'MSMerge_Delete conflict_table query' = @cmd
			exec (@cmd)
			if @@ERROR<>0 return (1)

		end

GO
GRANT EXECUTE ON [sys].[sp_deletemergeconflictrow] TO [public] AS [dbo]
GO
