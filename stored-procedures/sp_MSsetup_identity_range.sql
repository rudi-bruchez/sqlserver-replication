SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetup_identity_range]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetup_identity_range] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetup_identity_range]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@range_type [tinyint],
	@ranges_needed [tinyint],
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
    declare @subid uniqueidentifier
    declare @xe_message varbinary(1000)

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
        
    select @ident_increment = IDENT_INCR(@qualified_table_name)

    select @subid = NULL
    select @subid = subid from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid and (sys.fn_MSmerge_islocalsubid(subid)=1)
    if @subid is NULL
    begin
        raiserror(14050, 16, -1)
        return 1
    end

    select @xe_message = CAST('pubid: ' + convert(nvarchar(100), @pubid) + ', artid: ' + convert(nvarchar(100), @artid) + ', rangetype: ' + convert(nvarchar(100), @range_type) + ', rangesNeeded: ' + convert(nvarchar(100), @ranges_needed) + ', rangeBegin: ' + convert(nvarchar(100), @range_begin) + ', rangeEnd: ' + convert(nvarchar(100), @range_end) + ', nextRangeBegin: ' + convert(nvarchar(100), @next_range_begin) + ', nextRangeEnd: ' + convert(nvarchar(100), @next_range_end) AS varbinary(1000))
    exec master..sp_repl_generateevent 1, N'Event : identity_range_setup', @xe_message
    
    if not exists (select * from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range)
    begin
        -- create a new entry and add the identity range constraint to the table
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
                                    @next_range_end
            if @@ERROR<>0 or @retcode<>0
                return 1
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
                                    @ranges_needed
            if @@ERROR<>0 or @retcode<>0
                return 1
        end
        else
        begin
            if @ranges_needed = 2
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
GO
GRANT EXECUTE ON [sys].[sp_MSsetup_identity_range] TO [public] AS [dbo]
GO
