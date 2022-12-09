SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSallocate_new_identity_range]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSallocate_new_identity_range] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSallocate_new_identity_range]
	@subid [uniqueidentifier],
	@artid [uniqueidentifier],
	@range_type [tinyint],
	@ranges_needed [tinyint] OUTPUT,
	@range_begin [numeric](38, 0) OUTPUT,
	@range_end [numeric](38, 0) OUTPUT,
	@next_range_begin [numeric](38, 0) OUTPUT,
	@next_range_end [numeric](38, 0) OUTPUT,
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
declare @max_used numeric(38,0)
    declare @is_pub_range bit
    declare @range bigint
    declare @ident_increment numeric(38,0)
    declare @retcode int
    declare @objid int
    declare @qualified_table_name nvarchar(517)
    declare @applockname nvarchar(255)    
    declare @DbPrincipal sysname  

    

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @artid=@artid
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


    -- do the following resetting of pub's max_used to reflect the max_used only if 
    -- this is a root publisher and not if it is a republisher
    if (sys.fn_MSmerge_isrepublisher(@artid)=0)
    begin
        declare @publisher_max_used numeric(38,0)
        declare @pubid uniqueidentifier
        declare @pub_ranges_needed tinyint
        declare @pub_refresh_constraint bit
        
        select @pubid = subid, @publisher_max_used = max_used from dbo.MSmerge_identity_range 
            where artid = @artid and is_pub_range = 1 and (sys.fn_MSmerge_islocalpubid(subid)=1)
        if @pubid is NULL
        begin
            raiserror(20663, 16, -1)
            return 1
        end
        -- also update the publisher's identity range max to reflect this subscriber's allocation
        -- only if the subscriber thinks it has a valid allocation
        if @next_range_end is not NULL
        begin
            if (@ident_increment > 0 and @next_range_end > @publisher_max_used) or
               (@ident_increment < 0 and @next_range_end < @publisher_max_used)
            begin
                update dbo.MSmerge_identity_range 
                    set max_used = @next_range_end
                    where subid = @pubid and artid = @artid and is_pub_range = 1
                if @@error<>0
                begin
                    raiserror(20663, 16, -1)
                    return 1
                end
            end
        end

        -- find the local pubid and refresh the publisher's identity range allocation if this is a
        -- dbo user. This will be needed when publisher inserts are all done by non-dbo users.
        -- Code for refreshing the publisher range in the insert trigger will not be executed when 
        -- run by a non-dbo user.
        -- we need this to refresh the publisher's range here in that case. 
        -- Do this only when this is the root publisher and not a republisher. 
        -- The republisher's range will get refreshed when the merge agent runs.
        if (is_member('db_owner') = 1)
        begin
            select @pub_ranges_needed = 0
            if IDENT_CURRENT(@qualified_table_name) is NULL
                set @pub_refresh_constraint = 0
            else
                set @pub_refresh_constraint = 1

            -- sp_MScheck_publisher_range_refresh checks if ranges_need=0/1/2 and based on that value
            -- sp_MSrefresh_publisher_idrange allocates the ranges. If two threads call sp_MScheck.. at the same time
            -- decide ranges_needed=1 followed by a serialized call to sp_MSrefresh.., we will end up losing an range
            -- and IDENT_CURRENT value will be out of the allocated range (< range_begin). Hence the need to
            -- serialize the calls to sp_MScheck.. and sp_MSrefresh.. 
            -- see hotfix 50002854
            if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
                select @DbPrincipal = N'MSmerge_PAL_role'
            else
                select @DbPrincipal = N'db_owner'

            set @applockname= N'sp_MSallocate_new_identity_range_EX' + convert(nvarchar(11), db_id())
            -- wait for a maximum of 3 min to get the loc
            exec @retcode= sp_getapplock @Resource= @applockname, @LockMode= N'Exclusive', @LockOwner= N'Session', @LockTimeout= 180000, @DbPrincipal = @DbPrincipal 
            if @@error <> 0 or @retcode < 0
            begin
                raiserror(20666, 16, -1)
                return 1
            end
                        
            -- a previous snapshot has already setup the publisher range. So we will just refresh the subscriber's
            -- publisher range if needed here.
            exec @retcode = sys.sp_MScheck_publisher_range_refresh @qualified_table_name, @pubid, @artid, @pub_ranges_needed output
            if @retcode<>0 or @@error<>0
            begin
                exec sp_releaseapplock @Resource= @applockname, @LockOwner= N'Session', @DbPrincipal = @DbPrincipal                            
                raiserror (20689, 16, -1, @qualified_table_name)
                return (1)
            end
            if @pub_ranges_needed > 0
            begin
                exec @retcode = sys.sp_MSrefresh_publisher_idrange @qualified_table_name, @pubid, @artid, @pub_ranges_needed, @pub_refresh_constraint
                if @@error<>0 or @retcode<>0
                begin
                    exec sp_releaseapplock @Resource= @applockname, @LockOwner= N'Session', @DbPrincipal = @DbPrincipal                                                
                    raiserror(20666, 16, -1)
                    return 1
                end
            end
            exec sp_releaseapplock @Resource= @applockname, @LockOwner= N'Session', @DbPrincipal = @DbPrincipal                                
        end
    end

    if not exists (select * from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range)
    begin
        -- create an entry for this subscriber
        insert dbo.MSmerge_identity_range values (@subid, @artid, NULL, NULL, NULL, NULL, @is_pub_range, NULL)
        if @@error<>0
        begin
            raiserror(21197, 16, -1)
            return 1
        end
    end

    
    -- even if the range required is none, we will update the information stored on the publisher
    -- with what was passed in.
    if @ranges_needed = 0
    begin
        if @range_begin is NULL
        begin
            -- this is case when we are getting the first range for the subscriber
            if exists (select * from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range and range_begin is not NULL)
            begin
                select @range_begin = range_begin,
                       @range_end = range_end,
                       @next_range_begin = next_range_begin,
                       @next_range_end = next_range_end
                    from dbo.MSmerge_identity_range where subid=@subid and artid=@artid and is_pub_range=@is_pub_range
                select @ranges_needed = 2
            end
            else
            begin
                select @ranges_needed = 2 -- we will ask for 2 ranges here since this is the first allocation for this subscriber
                exec @retcode = sys.sp_MSget_new_idrange 
                                        @qualified_table_name, 
                                        @artid, 
                                        @range_begin output, 
                                        @range_end output, 
                                        @next_range_begin output, 
                                        @next_range_end output, 
                                        @range_type, 
                                        @ranges_needed 
                if @@error<>0 or @retcode<>0
                begin
                    raiserror(21197, 16, -1)
                    return 1
                end
                update dbo.MSmerge_identity_range 
                set range_begin = @range_begin, 
                    range_end = @range_end, 
                    next_range_begin = @next_range_begin, 
                    next_range_end = @next_range_end,
                    max_used = NULL
                where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    return 1
                end
            end
        end
        else
        begin
            update dbo.MSmerge_identity_range 
                set range_begin = @range_begin, 
                    range_end = @range_end, 
                    next_range_begin = @next_range_begin, 
                    next_range_end = @next_range_end,
                    max_used = @max_used
                where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
            if @@error<>0
            begin
                raiserror(21197, 16, -1)
                return 1
            end
        end
    end
    else
    begin
        -- get a new range for the given subscriber
        exec @retcode = sys.sp_MSget_new_idrange 
                                @qualified_table_name, 
                                @artid, 
                                @range_begin output, 
                                @range_end output, 
                                @next_range_begin output, 
                                @next_range_end output, 
                                @range_type, 
                                @ranges_needed
        if @@error<>0 or @retcode<>0
        begin
            raiserror(21197, 16, -1)
            return 1
        end
        
        update dbo.MSmerge_identity_range 
            set range_begin = @range_begin, 
                range_end = @range_end, 
                next_range_begin = @next_range_begin, 
                next_range_end = @next_range_end,
                max_used = @max_used
            where subid = @subid and artid = @artid and is_pub_range = @is_pub_range
        if @@error<>0
        begin
            raiserror(21197, 16, -1)
            return 1
        end
    end

    -- if we reached here it means that the range was successfully allocated. Call a stored procedure
    -- to log this information on the distributor. We need to add code in publisher restore from backup
    -- to pick up this information from the distributor and automatically set the max_used correctly.
    if @ranges_needed > 0
    begin
        exec @retcode = sys.sp_MSmerge_log_idrange_alloc_on_distributor    
                            @subid, 
                            @artid, 
                            @is_pub_range, 
                            @ranges_needed,
                            @range_begin,
                            @range_end,
                            @next_range_begin,
                            @next_range_end,
                            @publication,
                            @subscriber,
                            @subscriber_db
    end
    
    return 0

GO
GRANT EXECUTE ON [sys].[sp_MSallocate_new_identity_range] TO [public] AS [dbo]
GO
