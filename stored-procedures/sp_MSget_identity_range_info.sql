SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_identity_range_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_identity_range_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_identity_range_info]
	@subid [uniqueidentifier],
	@artid [uniqueidentifier],
	@range_type [tinyint],
	@ranges_needed [tinyint] OUTPUT,
	@range_begin [numeric](38, 0) OUTPUT,
	@range_end [numeric](38, 0) OUTPUT,
	@next_range_begin [numeric](38, 0) OUTPUT,
	@next_range_end [numeric](38, 0) OUTPUT
WITH EXECUTE AS CALLER
AS
declare @max_used numeric(38,0)
    declare @ident_increment numeric(38,0)
    declare @retcode int
    declare @is_pub_range bit
    declare @objid int
    declare @qualified_table_name nvarchar(517)

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    exec @retcode = sys.sp_MScheck_article_auto_identity @artid, @objid output, @qualified_table_name output
    if @retcode<>0 or @@error<>0
        return 1
        
    select @ident_increment = IDENT_INCR(@qualified_table_name)

    if @range_type = 1
    begin
        select @is_pub_range = 1
    end
    else
    begin
        select @is_pub_range = 0
    end
    
    if not exists (select * from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range)
    begin
        -- we did not find the entry to get information about it. The entry should be present
        -- when this proc is called. sp_MSsetup_identity_range proc called during the initial
        -- merge should have created the entry.

        -- however if this is an incrementally added article return information saying that both ranges are needed
        if exists (select * from dbo.sysmergearticles 
                    where artid=@artid and (status = 5 or status = 6) and 
                          pubid in (select pubid from dbo.sysmergesubscriptions where subid=@subid))
        begin
            return 0
        end
        else
        begin
            RAISERROR(20671, 16, -1)
            return (1)
        end
    end

    -- now check how much of the range has been used.
    select @range_begin = range_begin,
           @range_end = range_end,
           @next_range_begin = next_range_begin,
           @next_range_end = next_range_end,
           @max_used = max_used
        from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range
    if @is_pub_range = 0
    begin
        declare @ident_current numeric(38,0)
        select @ident_current = IDENT_CURRENT(@qualified_table_name)

        -- the range begin would be null if this is an attached subscription
        if @range_begin is NULL or @range_end is NULL
        begin
            select @ranges_needed = 2
            return 0
        end

        -- since range_begin above was not null it means that we have atleast one valid range in our 
        -- idrange metadata tables. Now if ident_curent is NULL then it means something is wrong.
        -- I have noticed that this is the case after upgrade from shiloh. To guard against possible
        -- shiloh bugs we will reseed the talbe to the first range begin
        if @ident_current is NULL
        begin
            -- if last_value is still null it means that server is going to start inserting from range_begin
            -- but we really want the server to start inserting from range_begin + ident_increment. Hence
            -- we need to do this extra step
            if exists (select 1 from sys.identity_columns where object_id=@objid and last_value is NULL)
            begin
                declare @temp_range_begin numeric(38,0)
                select @temp_range_begin = @range_begin + @ident_increment
                DBCC CHECKIDENT(@qualified_table_name, RESEED, @temp_range_begin) with no_infomsgs
                select @ident_current = IDENT_CURRENT(@qualified_table_name)
            end
            else
            begin
                DBCC CHECKIDENT(@qualified_table_name, RESEED, @range_begin) with no_infomsgs
                select @ident_current = IDENT_CURRENT(@qualified_table_name)
            end
        end

        -- here it is possible that on the subscriber the inserts were all done by non-dbo users
        -- in that case code that advances to using the next range in the insert trigger would not have got executed
        -- since we know that this proc was called by a user who is an admin on the subscriber, check
        -- here if we need to start using the second range and if so do the dbcc checkident        
        -- the id range check constraint refresh would have done a dbcc reseed only if both ranges
        -- are being refreshed. However we can be in a situation when (for positive increment)
        -- range_end <= ident_current < next_range_begin. In that case we need to do a reseed.
        if (@ident_increment > 0 and @range_end <= @ident_current and @ident_current < @next_range_begin) or
           (@ident_increment < 0 and @ident_current > @next_range_begin and @range_end >= @ident_current)
        begin
            DBCC CHECKIDENT(@qualified_table_name, RESEED, @next_range_begin) with no_infomsgs
            select @ident_current = IDENT_CURRENT(@qualified_table_name)
        end

        select @ranges_needed = sys.fn_MSMerge_get_ranges_needed( 
                                            @ident_increment, 
                                            @ident_current, 
                                            @range_begin, 
                                            @range_end, 
                                            @next_range_begin, 
                                            @next_range_end)

        -- next range begin would be NULL if this is an upgrade. In Shiloh we only allocated
        -- one range. We get that one range and put in in the range_begin and range_end values on
        -- upgrade. hence next range begin and end will be NULL after upgrade. So if this is
        -- the case we should request for atleast one range.
        if @next_range_begin is NULL or @next_range_end is NULL
        begin
            select @next_range_begin = @range_begin
            select @next_range_end = @range_end
            update dbo.MSmerge_identity_range 
                set next_range_begin = @next_range_begin,
                    next_range_end = @next_range_end
                where subid=@subid and artid=@artid and is_pub_range=@is_pub_range
        end
    end
    else
    begin
        -- the range begin would be null if this is an attached subscription
        if @range_begin is NULL or @range_end is NULL
        begin
            select @ranges_needed = 2
            return 0
        end
        
        select @ranges_needed = sys.fn_MSMerge_get_ranges_needed( 
                                            @ident_increment, 
                                            @max_used, 
                                            @range_begin, 
                                            @range_end, 
                                            @next_range_begin, 
                                            @next_range_end)
        
        -- next range begin would be NULL if this is an upgrade. In Shiloh we only allocated
        -- one range. hence next range begin and end will be NULL after upgrade. So if this is
        -- the case we should request for atleast one range.
        if @next_range_begin is NULL or @next_range_end is NULL
        begin
            select @next_range_begin = @range_begin
            select @next_range_end = @range_end
            update dbo.MSmerge_identity_range 
                set next_range_begin = @next_range_begin,
                    next_range_end = @next_range_end
                where subid=@subid and artid=@artid and is_pub_range=@is_pub_range
        end
    end

    return 0

GO
GRANT EXECUTE ON [sys].[sp_MSget_identity_range_info] TO [public] AS [dbo]
GO
