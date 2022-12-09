SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSispkupdateinconflict]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSispkupdateinconflict] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSispkupdateinconflict]
	@pubid [int],
	@artid [int],
	@bitmap [varbinary](4000)
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
        ,@tabname sysname
        ,@tabid int
        ,@indid int
        ,@indkey int
        ,@key sysname
        ,@colid int
        ,@isset int
        ,@artcol int
        ,@bytepos int
        ,@bitpos int

    --
    -- security check
    --
    exec @retcode = sp_MSreplcheck_publish
    if @@ERROR != 0 or @retcode != 0
    	return -1
    --
    -- initalize and validate
    --
    select @tabid = objid
        ,@indkey = 1
        ,@artcol = 0
    from dbo.sysarticles
    where (artid = @artid) and (pubid = @pubid)

    if (@tabid is null)
    begin
        raiserror(20046, 16, -1)
        return -1
    end
    
    select @tabname = QUOTENAME(schema_name(OBJECTPROPERTY(@tabid, 'SchemaId'))) collate database_default 
            + N'.' + QUOTENAME(object_name( @tabid )) collate database_default

    --
    -- get the Primary Key Index
    --
    select @indid = i.indid 
    from dbo.sysindexes i 
    where ((i.status & 2048) != 0) and (i.id = @tabid)
    if (@indid is null)
    begin
        raiserror(21750, 16, -1, @tabname)
        return -1
    end
    
    --
    -- create an enumeration of all the columns that are part of PK
    --
    create table #pkcoltab(pkindex int identity, keyname sysname collate database_default not null)
    while (@indkey <= 16)
    begin
        select @key = index_col( @tabname, @indid, @indkey )
        if (@key is null)
            break
        else
            insert into #pkcoltab(keyname) values(@key)

        select @indkey = @indkey + 1
    end

    --
    -- now walk through each article col and if it is
    -- a part of PK, then check if the update bitmap bit 
    -- corresponding to any article column is set
    --
    DECLARE #hCColid CURSOR LOCAL FAST_FORWARD FOR 
        select column_id, [name] from sys.columns 
        where object_id = @tabid order by column_id asc

    OPEN #hCColid
    FETCH #hCColid INTO @colid, @key
    WHILE (@@fetch_status != -1)
    begin
        exec @isset = sys.sp_isarticlecolbitset @colid, @artid
        if (@isset != 0)
        begin
        --
        -- this column is part of the article
        --
        select @artcol = @artcol + 1
        if exists (select * from #pkcoltab where keyname = @key)
        begin
            --
            -- this column is part of PK
            --
            select  @bytepos = 1 + (@artcol-1) / 8 
                ,@bitpos = power(2, (@artcol-1) % 8 )

            --
            -- if the update bitmap has bit set then
            -- then it is a PK update
            --
            if ((substring(@bitmap, @bytepos, 1) & @bitpos) = @bitpos)
                return 1
        end
        end
        --
        -- get the next column
        --
        FETCH #hCColid INTO @colid, @key
    end
    CLOSE #hCColid
    DEALLOCATE #hCColid
    drop table #pkcoltab

    --
    -- if we have reached here then it mean the update does not
    -- affect PK columns, cleanup and return
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSispkupdateinconflict] TO [public] AS [dbo]
GO
