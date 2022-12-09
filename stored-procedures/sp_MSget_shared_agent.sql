SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_shared_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_shared_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_shared_agent]
	@server_name [sysname],
	@database_name [sysname],
	@agent_type [int],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
    DECLARE @retcode    int

    SET @retcode = 0

    --
    -- security check
    -- only db_owner and replmonitor can execute this
    --
    if not ((is_member ('db_owner') = 1) or (isnull(is_member('replmonitor'),0) = 1))
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    
    -- push agents to SQL publications
    if @agent_type = 0
    begin
        if object_id('syssubscriptions') is not null
        begin
            DECLARE @publisher_type sysname

            EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher      = @publisher,
															@publisher_type = @publisher_type OUTPUT

            IF @retcode <> 0
                RETURN (@retcode)

            select	top 1
                    distribution_jobid AS N'job_id'
            from    syssubscriptions s,
                    sysarticles a,
                    syspublications p
            where   s.srvname = UPPER(@server_name) 
              and   s.dest_db            = @database_name
              and   s.subscription_type  = 0
              and   p.independent_agent  = 0
              and   s.artid              = a.artid
              and   p.pubid              = a.pubid
              and   p.pubid IN (SELECT * FROM sys.fn_IHgetpubid(p.name, @publisher, @publisher_type))
        end
    end
    -- push agents to third party
    else if @agent_type = 1
    begin
        if object_id('MSsubscriptions') is not null
        begin
            select    top 1 job_id AS N'job_id'
            from    MSdistribution_agents da,
                    MSreplservers spub,
                    MSreplservers ssub
            where    da.subscriber_id        = ssub.srvid
              and    da.subscriber_db        = @database_name
              and    da.publication            = N'ALL'
              and    da.publisher_id            = spub.srvid
              and    da.publisher_db            = @publisher_db
              and    da.subscription_type    = 0
              and    UPPER(spub.srvname)        = UPPER(@publisher) collate database_default
              and    UPPER(ssub.srvname)        = UPPER(@server_name) collate database_default
        end
    end
    else if @agent_type = 2
    begin
        if object_id('MSreplication_subscriptions') is not null
        begin
            -- For subscriptions added through Active X control
            -- where there's no local agent created, we still don't
            -- want to create new agent.
            select    top 1 agent_id as N'job_id'
            from    MSreplication_subscriptions
            where    UPPER(publisher)    = UPPER(@server_name)
              and    publisher_db        = @database_name
              and    independent_agent    = 0
              and    subscription_type in (1,2)
        end
    end
    
    RETURN (@retcode)
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_shared_agent] TO [public] AS [dbo]
GO
