SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_subscription_expiry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_subscription_expiry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_subscription_expiry]
	@pubid [uniqueidentifier],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@expired [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @status int
    declare @retcode int
    declare @subid uniqueidentifier
    declare @retention          int -- in time unit
    declare @retention_period_unit tinyint -- the time unit
    declare @recent_merge       datetime
    declare @minus_retention    datetime
    declare @pubname sysname
    declare @subscriber_type int

    if @pubid is NULL
    begin
		raiserror (14043, 11, -1, '@pubid', 'sp_MScheck_subscription_expiry')
		return (1)
    end
    
	exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid
	if @@error<>0 or @retcode<>0
	    return 1

    select @pubname = name, @retention = retention, @retention_period_unit = retention_period_unit from dbo.sysmergepublications where pubid = @pubid
    if @pubname is NULL
    begin
		raiserror (21723, 11, -1, 'sp_MScheck_subscription_expiry')
		return (1)
    end
    
    if @retention is not NULL and @retention > 0
    begin
        select @minus_retention = sys.fn_add_units_to_date(-@retention, @retention_period_unit, getdate())
        select @subid=subid, @status=status, @recent_merge = last_sync_date, @subscriber_type = subscriber_type 
            from dbo.sysmergesubscriptions where pubid=@pubid and db_name=@subscriber_db and 
    	        UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
    	if @subid is NULL
    	begin
    	    -- this could mean that for local or anonymous or lighweight subscriptions that we
    	    -- do not know about the subscription. For global subscriptions this should never happen.
    	    -- The reconciler should call this proc after ascertaining that the subscription exists
    	    if @subscriber_type = 1
    	        select @expired = 1
    	    else
        	    select @expired = 0
    	    return 0
    	end

    	if @status=2
    	begin
    	    select @expired = 1
    	end
    	else
    	begin
    	    if @recent_merge is not NULL and @recent_merge<@minus_retention
    	    begin
                update dbo.sysmergesubscriptions set status=2 where subid=@subid
                IF @@ERROR<>0
                    return 1
                select @expired = 1
    	    end
    	    else
    	        select @expired = 0
    	end         
    end
    else
        select @expired = 0

GO
GRANT EXECUTE ON [sys].[sp_MScheck_subscription_expiry] TO [public] AS [dbo]
GO
