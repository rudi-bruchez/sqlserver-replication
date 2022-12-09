SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

    select distinct ss.srvname + ':' collate database_default + s.subscriber_db, ss.srvname, s.subscriber_db, s.subscription_type, 
        sync_type, status, agent.name, agent.job_id from 
        dbo.MSsubscriptions s, MSreplservers ss, MSdistribution_agents agent where 
        s.publisher_id = (select srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)) and 
        s.publisher_db = @publisher_db and
        s.publication_id = (select publication_id from dbo.MSpublications where 
            publisher_id = s.publisher_id and
            publisher_db = s.publisher_db and
            publication = @publication) and
        ((@subscriber_db = N'%') or (s.subscriber_db = @subscriber_db)) and
        s.subscriber_id = ss.srvid and
        ((@subscriber = N'%') or (UPPER(ss.srvname) = UPPER(@subscriber))) and
        s.subscriber_id >= 0 and                    -- ignore virtual subscriptions
        s.agent_id = agent.id
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_subscription] TO [public] AS [dbo]
GO
