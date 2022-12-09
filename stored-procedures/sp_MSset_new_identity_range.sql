SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_new_identity_range]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_new_identity_range] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_new_identity_range]
	@subid [uniqueidentifier],
	@artid [uniqueidentifier],
	@range_type [tinyint],
	@ranges_given [tinyint],
	@range_begin [numeric](38, 0),
	@range_end [numeric](38, 0),
	@next_range_begin [numeric](38, 0),
	@next_range_end [numeric](38, 0)
WITH EXECUTE AS CALLER
AS
declare @max_used numeric(38,0)
    declare @retcode int
    declare @is_pub_range bit
    declare @objid int
    declare @qualified_table_name nvarchar(517)
    declare @ident_increment numeric(38,0)

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if @range_type = 1
    begin
        select @is_pub_range = 1
        select @max_used = @range_begin
    end
    else
    begin
        select @is_pub_range = 0
        select @max_used = NULL
    end
    
    exec @retcode = sys.sp_MScheck_article_auto_identity @artid, @objid output, @qualified_table_name output
    if @retcode<>0 or @@error<>0
        return 1

    if @range_begin is NULL or @range_end is NULL or @next_range_begin is NULL or @next_range_end is NULL 
    begin
        RAISERROR(20675, 16, -1)
        return (1)
    end
 
    select @ident_increment = IDENT_INCR(@qualified_table_name)
    
    if not exists (select * from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range)
    begin
        -- we did not find the entry to get information about it. The entry should be present
        -- when this proc is called. sp_MSsetup_identity_range proc called during the initial
        -- merge should have created the entry.

        -- however if this is an incrementally added article so insert an empty entry here
        if exists (select * from dbo.sysmergearticles 
                    where artid=@artid and (status = 5 or status = 6) and 
                          pubid in (select pubid from dbo.sysmergesubscriptions where subid=@subid))
        begin
            insert dbo.MSmerge_identity_range values (@subid, @artid, @range_begin, @range_end, @next_range_begin, @next_range_end, @is_pub_range, @max_used)
            if @@error<> 0
                return 1
            if @range_type = 2
            begin
                exec @retcode = sys.sp_MSrefresh_idrange_check_constraint 
                                        @qualified_table_name,
                                        @artid,
                                        @range_begin,
                                        @range_end,
                                        @next_range_begin,
                                        @next_range_end,
                                        @ranges_given
                if @@ERROR<>0 or @retcode<>0
                begin
                    RAISERROR(20670, 16, -1, @qualified_table_name)
                    return (1)
                end
            end
        end
        else
        begin
            RAISERROR(20671, 16, -1)
            return (1)
        end
    end
    else
    begin
        if @range_type = 2
        begin
            update dbo.MSmerge_identity_range 
                set range_begin = @range_begin, 
                    range_end = @range_end, 
                    next_range_begin = @next_range_begin, 
                    next_range_end = @next_range_end,
                    max_used = @max_used
                where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
            if @@error<> 0
                return 1

            exec @retcode = sys.sp_MSrefresh_idrange_check_constraint 
                                    @qualified_table_name,
                                    @artid,
                                    @range_begin,
                                    @range_end,
                                    @next_range_begin,
                                    @next_range_end,
                                    @ranges_given
            if @@ERROR<>0 or @retcode<>0
            begin
                RAISERROR(20670, 16, -1, @qualified_table_name)
                return (1)
            end
        end
        else
        begin
            if @ranges_given = 2
            begin
                update dbo.MSmerge_identity_range 
                    set range_begin = @range_begin, 
                        range_end = @range_end, 
                        next_range_begin = @next_range_begin, 
                        next_range_end = @next_range_end,
                        max_used = @max_used
                    where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
                if @@error<> 0
                    return 1
            end
            else
            begin
                -- set the current range to be the next range and newly given range to be the next range
                update dbo.MSmerge_identity_range 
                    set range_begin = next_range_begin, 
                        range_end = next_range_end
                    where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
                if @@error<> 0
                    return 1
            
                -- if we are getting only one new range we should not change the max_used column
                update dbo.MSmerge_identity_range 
                    set next_range_begin = @next_range_begin, 
                        next_range_end = @next_range_end
                    where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
                if @@error<> 0
                    return 1
            end
        end
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSset_new_identity_range] TO [public] AS [dbo]
GO
