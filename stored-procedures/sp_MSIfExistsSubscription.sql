SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSIfExistsSubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSIfExistsSubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSIfExistsSubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@type [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @publisher_id smallint
	declare @publication_id int

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	if @type not in (1,2)
	begin
		RAISERROR(21055, 16, -1, '@type','sp_MSIfExistsSubscription')
		RETURN (1)
	end

	set nocount on

    select @publisher_id = srvid from MSreplservers where
       UPPER(srvname) = UPPER(@publisher)

	if @type = 1
	begin
		select @publication_id = publication_id from dbo.MSpublications  where 
				publisher_id = @publisher_id and
				publisher_db = @publisher_db and
				publication = @publication and
				(publication_type = 0 or publication_type = 1)
	
		select TOP 1 1 from MSdistribution_agents a
			where exists (select * from dbo.MSsubscriptions s where
				(a.id = s.agent_id or a.anonymous_agent_id = s.agent_id) and
				s.publisher_id = @publisher_id and
				s.publisher_db = @publisher_db and
				-- For 6.x publisher, we don't know the association between the publication
				-- and subscriptions. Show every dist agent under each publication.
				(s.publication_id = @publication_id or s.publication_id = 0 ) and
				(a.subscriber_id >= 0  or a.subscriber_id is NULL))
	end
	else
	begin
		select @publication_id = publication_id from dbo.MSpublications  where 
				publisher_id = @publisher_id and
				publisher_db = @publisher_db and
				publication = @publication and
				publication_type = 2 -- Merge 
	
		select TOP 1 1 from dbo.MSmerge_agents 
			where publisher_id = @publisher_id and 
				publisher_db = @publisher_db and 
				publication = @publication
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MSIfExistsSubscription] TO [public] AS [dbo]
GO
