SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmetadatabatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmetadatabatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmetadatabatch]
	@pubid [uniqueidentifier],
	@tablenickarray [varbinary](2000),
	@rowguidarray [varbinary](8000),
	@compatlevel [int],
	@lightweight [int]
WITH EXECUTE AS CALLER
AS
declare @tablenick          int
    declare @tablenicklast      int
    declare @rowguid            uniqueidentifier
    declare @generation         bigint 
    declare @type                       tinyint
    declare @lineage            varbinary(311) 
    declare @colv                       varbinary(2953)
    declare @retcode        smallint
    declare @tnlength       int
    declare @tnoffset       int
    declare @guidoffset     int
    declare @procname       nvarchar(270)
    declare @iscoltracked   int
    declare @maxversion         int
    declare @cCols int

    -- create temp table for returning results
    declare @meta_batch TABLE (idx int identity unique, generation bigint, type tinyint,
        lineage varbinary(311), colv varbinary(2953), maxversion int)
        
    -- security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid=@pubid
    if @@error <> 0 or @retcode <> 0
            return 1

    set @tablenicklast = 0
    -- initialize offsets and length for walking through arrays
    set @tnoffset = 1
    set @guidoffset = 1
    set @tnlength = datalength(@tablenickarray)

-- DEBUG    declare @debugtime datetime
-- DEBUG    set @debugtime= getdate()

    -- walk through arrays and populate temp table
    while (@tnoffset < @tnlength)
    begin
        set @tablenick = substring(@tablenickarray, @tnoffset, 4)
        set @rowguid = substring(@rowguidarray, @guidoffset, 16)

        -- instead of calling sp_MSgetrowmetadata, look it up ourselves might be faster
        
        --  exec @rc = sp_MSgetrowmetadata @tablenick, @rowguid,  @generation output,
        --  @type  output, @lineage output, @colv output, @pubid
        if @tablenick <> @tablenicklast
            begin
            select @procname= 'dbo.' + select_proc, @iscoltracked= column_tracking from dbo.sysmergearticles where nickname = @tablenick and pubid=@pubid
            set @tablenicklast = @tablenick
            end

        set @type= 4
        set @generation= 0
        set @lineage= NULL
        set @colv= NULL

        -- check for row in base table
        exec @retcode= @procname @maxschemaguidforarticle = NULL, @type=@type output, @rowguid=@rowguid
        if @@error <>0 or @retcode <> 0 
        begin
            return (1)
        end

        select @cCols = 0
        if (@type = 3)
        begin
            if @compatlevel < 90
            begin
                set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
            end

            -- here do a union query between contents and tombstone
            -- The normal case here would be: Either the row is in contents or if the row
            -- was added as part of the initial snapshot it does not have a contents row 
            -- however, in the exception case, if there is some partition movement or some 
            -- deletes happening while we do this query, the row could have been deleted
            -- and the MSmerge_contents entry for the row will not be present.
            -- To cover the exception case we do a union query here between contents and tombstones.
            select @type = type, @generation = generation, @lineage = lineage, @colv = colv from
            (
                select 2 as type,  generation as generation, 
                       case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end as lineage, 
                       case when @compatlevel >= 90 or @iscoltracked = 0 then colv1 else {fn COLV_90_TO_80(colv1, @cCols)} end as colv
                    from dbo.MSmerge_contents
                    where tablenick = @tablenick and rowguid = @rowguid
                union
                select type as type, generation as generation, 
                       case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end as lineage,
                       NULL as colv
                    from dbo.MSmerge_tombstone
                    where tablenick = @tablenick and rowguid = @rowguid
            ) as metadataunion
            
        end
        else
        begin
            set @type= 0
            
            if @compatlevel < 90
            begin
                set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
            end
            
            -- here do a union query between contents and tombstone
            -- The normal case here would be: Either the row is in tombstones or if the row
            -- was never present it will have no entry in tombstone. 
            -- however, in the exception case, if there is some partition movement or some 
            -- re-inserts happening while we do this query, the row could have been re-inserted
            -- and the tombstone entry will not be present.
            -- To cover the exception case we do a union query here between contents and tombstones.
            -- which should be done as an atomic operation.
            select @type = type, @generation = generation, @lineage = lineage, @colv = colv from
            (
                select 2 as type,  generation as generation, 
                       case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end as lineage, 
                       case when @compatlevel >= 90 or @iscoltracked = 0 then colv1 else {fn COLV_90_TO_80(colv1, @cCols)} end as colv
                    from dbo.MSmerge_contents
                    where tablenick = @tablenick and rowguid = @rowguid
                union
                select type as type, generation as generation, 
                       case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end as lineage,
                       NULL as colv
                    from dbo.MSmerge_tombstone
                    where tablenick = @tablenick and rowguid = @rowguid
            ) as metadataunion2
            
        end
 
-- DEBUG        insert into MSmerge_debug (okay, artnick, rowguid, type, generation_new, lineage_new, twhen, comment)
-- DEBUG            values (0, @tablenick, @rowguid, @type, @generation, @lineage, @debugtime, 'sp_MSgetmetadatabatch')

        -- insert values into temp table
        if @lightweight <> 0
        begin
            select @maxversion= maxversion_at_cleanup from dbo.sysmergearticles 
                    where nickname = @tablenick and pubid=@pubid

            insert into @meta_batch (generation, type, lineage, colv, maxversion) values
                (@generation, @type, @lineage, @colv, @maxversion) 
        end
        else
        begin
            insert into @meta_batch (generation, type, lineage, colv) values
                (@generation, @type, @lineage, @colv) 
        end

        -- bump up offsets for next time through loop
        set @tnoffset = @tnoffset + 4
        set @guidoffset = @guidoffset + 16
    end

    -- select out our result set
    if @lightweight <> 0
    begin
        select generation, type, lineage, colv, maxversion from @meta_batch order by idx
    end
    else
    begin
        select generation, type, lineage, colv from @meta_batch order by idx
    end

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetmetadatabatch] TO [public] AS [dbo]
GO
