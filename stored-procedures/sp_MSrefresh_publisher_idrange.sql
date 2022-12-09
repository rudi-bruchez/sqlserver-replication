SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrefresh_publisher_idrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrefresh_publisher_idrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrefresh_publisher_idrange]
	@qualified_object_name [nvarchar](517),
	@subid [uniqueidentifier],
	@artid [uniqueidentifier],
	@ranges_needed [tinyint],
	@refresh_check_constraint [bit]
WITH EXECUTE AS CALLER
AS
declare @range_begin numeric(38,0)
    declare @range_end numeric(38,0)
    declare @next_range_begin numeric(38,0)
    declare @next_range_end numeric(38,0)
    declare @retcode int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error<>0 or @retcode<>0
        return 1
    
    if @ranges_needed=0
        return 0

    if @artid is NULL
    begin
        select @artid=artid from dbo.sysmergearticles where objid=object_id(@qualified_object_name)
        if @artid is NULL
        begin
            RAISERROR (20027, 16, -1, @qualified_object_name)
            RETURN (1)
        end
    end

    select @range_begin = range_begin,
           @range_end = range_end,
           @next_range_begin = next_range_begin,
           @next_range_end = next_range_end
        from dbo.MSmerge_identity_range where artid=@artid and subid=@subid and is_pub_range=0
   
    exec @retcode = sys.sp_MSget_new_idrange 
                            @qualified_object_name, 
                            @artid, 
                            @range_begin output, 
                            @range_end output, 
                            @next_range_begin output, 
                            @next_range_end output, 
                            2, -- subscriber range. This is the publisher's local range.
                            @ranges_needed
    if @@error<>0 or @retcode<>0
    begin
        raiserror(21197, 16, -1)
        return 1
    end

    if @refresh_check_constraint=1 and @qualified_object_name is not NULL
    begin
        exec @retcode = sys.sp_MSrefresh_idrange_check_constraint @qualified_object_name, @artid, @range_begin, @range_end, @next_range_begin, @next_range_end, @ranges_needed
        if @@error<>0 or @retcode<>0
        begin
            raiserror(21197, 16, -1)
            return 1
        end
    end

    update dbo.MSmerge_identity_range 
        set range_begin = @range_begin,
            range_end = @range_end,
            next_range_begin = @next_range_begin,
            next_range_end = @next_range_end
        where subid=@subid and artid=@artid and is_pub_range=0
    if @@ERROR<>0 
    begin
        raiserror(21197, 16, -1)
        return 1
    end

    -- also update on the distributor the identity range that was just allocated to the publisher
    -- we will do this only for the root publisher. When a republisher gets restored from backup
    -- it should merge with its root publisher to get the information on what ranges were allocated.
    exec @retcode = sys.sp_MSmerge_log_idrange_alloc_on_distributor    
                        @subid,
                        @artid, 
                        0, -- is_pub_range 0 because in Yukon publisher's local allocation is the size of the sub range.
                        @ranges_needed,
                        @range_begin,
                        @range_end,
                        @next_range_begin,
                        @next_range_end
    
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSrefresh_publisher_idrange] TO [public] AS [dbo]
GO
