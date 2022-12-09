SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_subscription_status]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_subscription_status] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_subscription_status]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@retention [int],
	@out_of_date [int] OUTPUT,
	@independent_agent [bit]
WITH EXECUTE AS CALLER
AS
declare @subscriber_id          int
declare @publisher_id           int
declare @publication_id         int
declare @retcode                int
declare @agent_id               int
declare @min_valid_day          datetime
declare @subscription_time      datetime
declare @last_history			datetime
declare @last_status			int

/*
** Security check.  'sysadmin' or db_owner of distribution db required. 
*/
EXEC @retcode = sys.sp_MSreplcheck_publish
IF @@ERROR <> 0 or @retcode <> 0
    return (1)

select @out_of_date = 0 -- Default value set to in-sync
select @publisher_id = srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@publisher)
select @subscriber_id = srvid from MSreplservers where UPPER(srvname collate database_default)=UPPER(@subscriber)

select  @publication_id = publication_id
        from MSpublications where
        publisher_id = @publisher_id and
        publisher_db = @publisher_db and
        publication = @publication

select @subscription_time = subscription_time
        from MSsubscriptions where
            publisher_id = @publisher_id and
            publisher_db = @publisher_db and
            publication_id = @publication_id and
            subscriber_id = @subscriber_id and
            subscriber_db = @subscriber_db
            
select @min_valid_day = dateadd(hour, -@retention, getdate())
        
BEGIN TRAN
    select @agent_id = id from MSdistribution_agents 
        where   publisher_id = @publisher_id and 
                publisher_db = @publisher_db and 
                ((publication = @publication and @independent_agent = 1 ) 
                    or (LOWER(publication) = 'all' and @independent_agent = 0)) and
                subscriber_id = @subscriber_id and  
                subscriber_db = @subscriber_db

    if @agent_id is NOT NULL
        begin
        	select Top 1 @last_status = runstatus, @last_history = time 
        		from MSdistribution_history where agent_id = @agent_id
        			order by timestamp DESC
        			
            if EXISTS (select * from MSdistribution_history where agent_id = @agent_id) and (@last_history < @min_valid_day)
                and (@retention <> 0)
                select @out_of_date = 1
            else 
                if (not EXISTS (select * from MSdistribution_history where agent_id = @agent_id)) and
                        (@subscription_time < @min_valid_day) and (@retention <> 0)
                select @out_of_date = 1
        end
        
COMMIT TRAN
return (0)

FAILURE:
    if @@TRANCOUNT = 1
        ROLLBACK TRAN
    else
        COMMIT TRAN
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MShelp_subscription_status] TO [public] AS [dbo]
GO
