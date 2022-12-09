SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgettrancftsrcrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgettrancftsrcrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgettrancftsrcrow]
	@tran_id [sysname],
	@row_id [sysname],
	@conflict_table [nvarchar](270),
	@is_subscriber [bit],
	@is_debug [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @decllist nvarchar(4000)
            ,@sellist nvarchar(4000)
            ,@wherelist nvarchar(4000)
            ,@cmd nvarchar(4000)
            ,@cmdrow nvarchar(4000)
            ,@srctable sysname
            ,@srctabid int
            ,@srcowner sysname
            ,@indid int
            ,@indkey int
            ,@key sysname
            ,@this_col int
            ,@col sysname
            ,@typestring nvarchar(60)
            ,@dbname sysname
            ,@retcode int
            ,@unqualified_cft_tab sysname
            ,@startoffset int
            ,@artid int
            ,@publication sysname
    declare @decltext table ( c1 int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)
    declare @seltext table ( c1 int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)
    declare @wheretext table ( c1 int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

    --
    -- validate input
    --
    if ((@tran_id is null) or (@row_id is null) or 
        (@conflict_table is null) or (@is_subscriber is null))
    begin
        raiserror(14043, 16, 1, '@tran_id or @row_id or @conflict_table or @is_subscriber', 'sp_MSgettrancftsrcrow')
        return (1)
    end
    --
    -- check if the conflict table is owner qualified
    --
    select @startoffset = charindex(N'].[', @conflict_table, 0)
    select @unqualified_cft_tab = case when (@startoffset > 0) 
        then substring(@conflict_table, @startoffset + 2, len(@conflict_table) - @startoffset - 1)
        else quotename(@conflict_table) end        
    --
    -- get the source table info, publication name
    --
    if (@is_subscriber = 1)
    begin
        --
        -- we are on subscriber
        --
        select @srcowner = sart.owner, @srctable = sart.dest_table 
            ,@srctabid = OBJECT_ID(sart.dest_table)
            ,@publication = sagnt.publication
        from (MSsubscription_articles as sart join MSsubscription_agents as sagnt 
                on sart.agent_id = sagnt.id)
        where quotename(sart.cft_table) = @unqualified_cft_tab
    end
    else
    begin
        --
        -- we are on publisher
        --
        select @srcowner = schema_name(OBJECTPROPERTY(a.objid,'SchemaId'))
            ,@srctable = OBJECT_NAME(a.objid)
            ,@srctabid = a.objid, @artid = a.artid
            ,@publication = p.name
        from ((sysarticles a join sysarticleupdates b 
            on a.pubid = b.pubid 
            and a.artid = b.artid) join syspublications p 
                on a.pubid = p.pubid)
        where b.conflict_tableid = OBJECT_ID(@conflict_table)
    end
    --
    -- Do PAL security check
    --
    exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
    if @retcode <> 0 or @@error <> 0
        return (1)
    --
    -- create code for the following :
    -- select the row of conflict with given tranid and insertdate
    -- retrieve the values of the PK/UI columns for the source table from this row in cft_table
    -- select all columns from source table using the values in a where clause for PK/UI
    --

    --
    -- PK/UI check for source table
    --
    exec @indid = sys.sp_MStable_has_unique_index @srctabid
    if (@indid = 0)
    begin
        raiserror(21750, 16, 1, @srctable)
        return (1)
    end
    --
    -- walk through each column in PK/UI and build parts of code
    --
    select @indkey = 1
    while (@indkey <= 16)
    begin   
		select @key = index_col(quotename(@srcowner) + N'.' + quotename(@srctable), @indid, @indkey)
        if (@key is null)
        begin
            select @indkey = 16
        end
        else
        begin
            --
            -- get the column index in the source table for this index key
            --
            exec sys.sp_MSget_col_position @srctabid, @artid, @key, @col output, @this_col output
            --
            -- get the typestring for this column in source table
            --
            select @typestring = sys.fn_gettypestring(@srctabid, @this_col, 1, 0, 0, 0, 1, 0, 0, 0, 0) -- LUDT+Spatial merge conflict trigger 
            --
            -- build command strings
            --
            if (@decllist is NULL)
                select @decllist = N'declare @' + @col + N' ' + @typestring
            else
                select @decllist = N' ,@' + @col + N' ' + @typestring
            
            if (@sellist is NULL)
                select @sellist = N'select @' + @col + N' = ' + quotename(@key)
            else
                select @sellist = N' ,@' + @col + N' = ' + quotename(@key)
                
            if (@wherelist is NULL)
                select @wherelist = N'where ' + quotename(@key) + N' = @' + @col
            else
                select @wherelist = N' and ' + quotename(@key) + N' = @' + @col
            --
            -- store them in the temp tables
            --
            insert into @decltext(cmdtext) values(@decllist)
            insert into @seltext(cmdtext) values(@sellist)
            insert into @wheretext(cmdtext) values(@wherelist)
        end
        select @indkey = @indkey + 1
    end
    --
    -- Now put all the code in order in the codetext
    --
    create table #MSsrcrow_codetext ( step int identity NOT NULL, cmdtext nvarchar(4000) NULL)

    insert into #MSsrcrow_codetext(cmdtext)
        select cmdtext from @decltext order by c1
    insert into #MSsrcrow_codetext(cmdtext) values (N' ')
    insert into #MSsrcrow_codetext(cmdtext)
        select cmdtext from @seltext order by c1
    select @cmd = N' 
    from ' 

    if (@startoffset > 0)
        select @cmd = @cmd + @conflict_table
    else
        select @cmd = @cmd + quotename(@srcowner) + N'.' + @unqualified_cft_tab
        
    select @cmd = @cmd + N'
    where tranid = ''' + @tran_id + ''' and qcfttabrowid = ''' + @row_id + ''' '
    insert into #MSsrcrow_codetext(cmdtext) values (@cmd)
    select @cmd = N'select * from ' + quotename(@srcowner) + N'.' + quotename(@srctable) + N' '
    insert into #MSsrcrow_codetext(cmdtext) values (@cmd)
    insert into #MSsrcrow_codetext(cmdtext)
        select cmdtext from @wheretext order by c1
    --
    -- now execute the code we just built
    --
    if (@is_debug = 0)
    begin
        select @cmd = N'select cmdtext from #MSsrcrow_codetext order by step'
                 ,@dbname = db_name()
        exec @retcode = sys.xp_execresultset @cmd, @dbname
        if (@@error != 0 or @retcode != 0)
        begin
            raiserror(21465, 16, 1, 'xp_execresultset')
            return (1)
        end
    end
    else
        select cmdtext from #MSsrcrow_codetext order by step 

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSgettrancftsrcrow] TO [public] AS [dbo]
GO
