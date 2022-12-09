SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetgentozero]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetgentozero] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetgentozero]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@metatype [tinyint]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @METADATA_TYPE_Tombstone tinyint
    declare @METADATA_TYPE_Contents tinyint
    declare @METADATA_TYPE_PartialDelete tinyint
    declare @METADATA_TYPE_SystemDelete tinyint

    set @METADATA_TYPE_Tombstone= 1
    set @METADATA_TYPE_Contents= 2
    set @METADATA_TYPE_PartialDelete= 5
    set @METADATA_TYPE_SystemDelete= 6
    
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSsetgentozero')
        return (1)
    end
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSsetgentozero')
        return (1)
    end
    if (@metatype is not null and 
        @metatype not in (@METADATA_TYPE_Tombstone,
                          @METADATA_TYPE_Contents,
                          @METADATA_TYPE_PartialDelete,
                          @METADATA_TYPE_SystemDelete))
    begin
        --RAISERROR(20052, 16, -1)
        return 0
    end

    -- security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if @metatype in (@METADATA_TYPE_Tombstone,
                     @METADATA_TYPE_PartialDelete,
                     @METADATA_TYPE_SystemDelete)
    begin
                update dbo.MSmerge_tombstone 
                        set generation = 0
                        where tablenick = @tablenick and rowguid = @rowguid
    end
    else if @metatype = @METADATA_TYPE_Contents
    begin
                update dbo.MSmerge_contents 
                        set generation = 0
                        where tablenick = @tablenick and rowguid = @rowguid

                update dbo.MSmerge_past_partition_mappings 
                        set generation = 0 
                        where tablenick = @tablenick and rowguid = @rowguid
    end
    else
    begin
                update dbo.MSmerge_tombstone 
                        set generation = 0
                        where tablenick = @tablenick and rowguid = @rowguid

                if 0 = @@rowcount
                begin
                        update dbo.MSmerge_contents 
                                set generation = 0
                                where tablenick = @tablenick and rowguid = @rowguid
                end
        
        update dbo.MSmerge_past_partition_mappings 
            set generation = 0 
            where tablenick = @tablenick and rowguid = @rowguid
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSsetgentozero] TO [public] AS [dbo]
GO
