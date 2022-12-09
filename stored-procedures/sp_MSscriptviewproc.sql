SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscriptviewproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscriptviewproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscriptviewproc]
	@viewname [sysname],
	@ownername [sysname],
	@procname [sysname],
	@rgcol [sysname],
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode            smallint
    declare @view_id            int
    declare @xtype              int
    declare @system_type_id             int   
    declare @max_length                 int 
    declare @column_is_blob     bit
    declare @loop_counter       int
    declare @colid int
    declare @colcount int
    declare @collist_blob_command nvarchar(max)
    declare @collist_actual_command nvarchar(max)
    declare @replnick binary(6)
	declare @quoted_procname	nvarchar(258)

    set nocount on

    select @retcode = 0

    -- security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid=@pubid
    if @@error <> 0 or @retcode <> 0
        return 1

    -- instead of computing the column list use the one from sysmergepartitioninfo
    -- the column lists in sysmergepartitioninfo should have been populated by the select
    -- proc. Hence always remember to call this proc after calling the select proc
    select @collist_actual_command = column_list, @collist_blob_command = column_list_blob
    from dbo.sysmergepartitioninfo where artid = @artid and pubid=@pubid

    declare @proctext table (line_no int primary key identity(1,1), line nvarchar(max))
    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 

    exec @retcode = sys.sp_MSgetreplnick @replnick = @replnick out
    if (@retcode <> 0) or @replnick IS NULL 
    begin
        raiserror(14055, 11, -1)
        return(1)
    end                 

    select @quoted_procname=QUOTENAME(@procname)
        
    insert into @proctext (line) values ('
create procedure dbo.' + @quoted_procname + ' (
    @tablenick int, 
    @max_rows int = NULL,
    @guidlast uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', 
    @compatlevel int = 10, 
    @pubid uniqueidentifier = NULL, 
    @enumentirerowmetadata bit= 1,
    @blob_cols_at_the_end bit = 0
) 
as
begin
    set nocount on
    set rowcount 0
    
    declare @retcode int

    -- security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick=@tablenick
    if @@error <> 0 or @retcode <> 0
            return 1
                
    if  @max_rows is not null
    begin
        -- used to select data for initial pop. of subscriber for dynamic filtered publication

        declare @maxint int
        declare @lin varbinary (311)
        declare @cv varbinary (2953)
        declare @replnick varbinary(6)
        declare @coltracked int
        declare @colv80 varbinary (2953)

        select @coltracked = sys.fn_fIsColTracked(@tablenick)
        select @colv80 = sys.fn_cColvEntries_80(@pubid, @tablenick)


        set @maxint= 2147483647

        if 0 = @max_rows
        begin
            set @max_rows= @maxint
        end
            
        select @replnick = ' + sys.fn_varbintohexstr(@replnick) + ' 
        set @lin = { fn UPDATELINEAGE(0x0, @replnick, 1) }
        set @cv = 0xFF

        if @blob_cols_at_the_end = 0
        begin
            select top (@max_rows)
                @tablenick,
                t.' + quotename(@rgcol) + ',
                coalesce(c.generation,1),
                case 
                        when 0=@enumentirerowmetadata then null 
                        when @compatlevel >= 90 then coalesce(c.lineage, @lin) 
                        else {fn LINEAGE_90_TO_80(coalesce(c.lineage, @lin))}
                end, 
                case 
                        when 0=@enumentirerowmetadata then null 
                        when @compatlevel >= 90 or @coltracked = 0 then coalesce(c.colv1, @cv) 
                        else {fn COLV_90_TO_80(coalesce(c.colv1, @cv), @colv80)}
                end
')
    if @@error <> 0 or @retcode <> 0 
    begin 
        select @retcode = 1 
        goto Failure 
    end 
    
    if @collist_actual_command is not null
    begin
        insert into @proctext (line) select ' ,' + @collist_actual_command
        if @@error <> 0 or @retcode <> 0 
        begin 
            select @retcode = 1 
            goto Failure 
        end 
    end
            
    insert into @proctext (line) values ('
              from ' +
                    QUOTENAME(@ownername) + '.' +
                        QUOTENAME(@viewname) + ' t left outer join  dbo.MSmerge_contents c on
                          t.' + quotename(@rgcol) + ' = c.rowguid  and c.tablenick = @tablenick where t.' + quotename(@rgcol) + ' > @guidlast 
                         order by t.' + quotename(@rgcol) + '
        end
        else
        begin
            select top (@max_rows)
                @tablenick,
                t.' + quotename(@rgcol) + ',
                coalesce(c.generation,1),
                case 
                        when 0=@enumentirerowmetadata then null 
                        when @compatlevel >= 90 then coalesce(c.lineage, @lin) 
                        else {fn LINEAGE_90_TO_80(coalesce(c.lineage, @lin))}
                end, 
                case 
                        when 0=@enumentirerowmetadata then null 
                        when @compatlevel >= 90 or @coltracked = 0 then coalesce(c.colv1, @cv) 
                        else {fn COLV_90_TO_80(coalesce(c.colv1, @cv), @colv80)}
                end
')
    if @@error <> 0 or @retcode <> 0 
    begin 
        select @retcode = 1 
        goto Failure 
    end 
    
    if @collist_blob_command is not null
    begin    
        insert into @proctext (line) select ' ,' + @collist_blob_command
        if @@error <> 0 or @retcode <> 0 
        begin 
            select @retcode = 1 
            goto Failure 
        end 
    end
        
    insert into @proctext (line) values ('
              from ' +
                    QUOTENAME(@ownername) + '.' +
                        QUOTENAME(@viewname) + ' t left outer join  dbo.MSmerge_contents c on
                          t.' + quotename(@rgcol)  + ' = c.rowguid  and c.tablenick = @tablenick where t.' + quotename(@rgcol)  + ' > @guidlast 
                         order by t.' + quotename(@rgcol)  + '
        end

        return (1)      
    end

    insert into #belong (tablenick, rowguid, flag, skipexpand, partchangegen)
        select ct.tablenick, ct.rowguid, 0, 0, ct.partchangegen
          from  #contents_subset ct, ' + QUOTENAME(@ownername) + '.' +
                        QUOTENAME(@viewname) + ' t where ct.tablenick = @tablenick
           and ct.rowguid = t.' + quotename(@rgcol)  + '  
    if @@error <> 0
    begin
        raiserror(''Error selecting from view'' , 16, -1)
        return (1)  
    end
end
')

    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 
    select line from @proctext order by line_no asc

Failure:
    return @retcode 
end
GO
GRANT EXECUTE ON [sys].[sp_MSscriptviewproc] TO [public] AS [dbo]
GO
