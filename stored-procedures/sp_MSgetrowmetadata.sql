SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetrowmetadata]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetrowmetadata] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetrowmetadata]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@generation [bigint] OUTPUT,
	@type [tinyint] OUTPUT,
	@lineage [varbinary](311) OUTPUT,
	@colv [varbinary](2953) OUTPUT,
	@pubid [uniqueidentifier],
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
declare @retcode        smallint
    declare @rc             int
    declare @procname       nvarchar(270)
    
    /*
    ** To public.
    */
    
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSgetrowmetadata')
        return (1)
    end
        
    -- security check
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick=@tablenick, @pubid = @pubid
        if @@error <> 0 or @retcode <> 0
                return 1
                
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSgetrowmetadata')
        return (1)
    end

    set @type= 4
    set @generation= 0
    set @lineage= NULL
    set @colv= NULL

    select @procname= 'dbo.' + select_proc from dbo.sysmergearticles where nickname = @tablenick and pubid = @pubid

    -- check for row in base table
    exec @retcode= @procname @maxschemaguidforarticle = NULL, @type=@type output, @rowguid=@rowguid
    if @@error <>0 or @retcode <> 0 
    begin
        return (1)
    end

    begin tran
    if (@type = 3)
    begin
        if @compatlevel < 90
        begin
            declare @iscoltracked int
            declare @cCols int
            set @iscoltracked= sys.fn_fIsColTracked(@tablenick)
            if @iscoltracked = 1
            begin
                set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
            end
        end

        -- row is in base table; check whether it is in contents, too
        --
        -- serializable makes sure row does not go from tombstone to contents between 
        -- querying contents and tombstone, which would falsely result in type = missing
        select @type= 2,  @generation= generation, 
               @lineage= case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end, 
               @colv= case when @compatlevel >= 90 or @iscoltracked = 0 then colv1 else {fn COLV_90_TO_80(colv1, @cCols)} end
            from dbo.MSmerge_contents
            with (serializable)
            where tablenick = @tablenick and rowguid = @rowguid
    end
    else
    begin
        -- row is not in base table; either it is in tombstone, or it is missing
        set @type= 0

        select @type= type, @generation= generation, 
               @lineage= case when @compatlevel >= 90 then lineage else {fn LINEAGE_90_TO_80(lineage)} end 
            from dbo.MSmerge_tombstone where
            tablenick = @tablenick and rowguid = @rowguid
    end
    commit tran
    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetrowmetadata] TO [public] AS [dbo]
GO
