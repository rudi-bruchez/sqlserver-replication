SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetdatametadatabatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetdatametadatabatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetdatametadatabatch]
	@pubid [uniqueidentifier],
	@tablenickarray [varbinary](2000),
	@rowguidarray [varbinary](8000),
	@all_articles_are_guaranteed_to_be_updateable_at_other_replica [bit],
	@logical_record_parent_rowguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @tablenick int
    declare @rowguid uniqueidentifier
    declare @retcode        smallint
    declare @tnlength       int
    declare @tnoffset       int
    declare @guidoffset     int
    declare @procname       nvarchar(270)
    declare @enumrowmetadataforthatarticle      bit
    declare @nextnicknameminidx int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    -- create temp table for returning results
    create table #rows (idx int identity(1,1) unique, tablenick int, rowguid uniqueidentifier)
    create index #rows_rowguid_index on #rows (rowguid)

    if (@tablenickarray is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSgetdatametadatabatch')
        return (1)
    end
    if (@rowguidarray is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSgetdatametadatabatch')
        return (1)
    end
   
    -- initialize offsets and length for walking through arrays
    set @tnoffset = 1
    set @guidoffset = 1
    set @tnlength = datalength(@tablenickarray)

    -- walk through arrays and populate temp table
    while (@tnoffset < @tnlength)
    begin
        set @tablenick = substring(@tablenickarray, @tnoffset, 4)
        set @rowguid = substring(@rowguidarray, @guidoffset, 16)

        insert into #rows (tablenick, rowguid) values (@tablenick, @rowguid) 

        -- bump up offsets for next time through loop
        set @tnoffset = @tnoffset + 4
        set @guidoffset = @guidoffset + 16
    end

        select @tablenick = NULL
        select @nextnicknameminidx=1
    select @tablenick = tablenick from #rows where idx=@nextnicknameminidx
    
    while (@tablenick is not NULL)
    begin
        select @procname = 'dbo.' + select_proc from dbo.sysmergearticles
                where pubid = @pubid and nickname = @tablenick

        if 0 = @all_articles_are_guaranteed_to_be_updateable_at_other_replica and 
           1 = sys.fn_MSarticle_has_downloadonly_property(@tablenick)
        begin
            set @enumrowmetadataforthatarticle= 0
        end
        else
        begin
            set @enumrowmetadataforthatarticle= 1
        end
        
        exec @retcode = @procname 
                            @maxschemaguidforarticle = NULL, 
                            @type= 9,
                            @enumentirerowmetadata= @enumrowmetadataforthatarticle,
                            @logical_record_parent_rowguid = @logical_record_parent_rowguid
        if @@error <> 0 or @retcode <> 0
            return 1
        
        select @nextnicknameminidx = min(idx) from #rows
        where idx >  @nextnicknameminidx
        and tablenick != @tablenick
        
        if @nextnicknameminidx is null
            break
        
        select @tablenick = min(tablenick) from #rows 
        where idx = @nextnicknameminidx
    end

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetdatametadatabatch] TO [public] AS [dbo]
GO
