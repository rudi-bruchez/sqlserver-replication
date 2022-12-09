SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_repl_alert]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_repl_alert] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_repl_alert]
	@agent_type [int],
	@agent_id [int],
	@error_id [int],
	@alert_error_code [int],
	@xact_seqno [varbinary](16),
	@command_id [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@alert_error_text [nvarchar](max)
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	declare @retcode int
	declare @article sysname
	declare @article_id int
	declare @destination_object sysname
	declare @source_object sysname
	declare @publisher_id int
	declare @publication sysname
	declare @publication_id int
	declare @publication_type int
	declare @subscriber_id int
	declare @publisher_database_id int
	declare @agent_type2 int

	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_repl_alert', 'distribution')
		return (1)
	end
	-- Security Check
	if @agent_type = 3
		select @agent_type2 = 0 -- distribution
	else if (@agent_type & 4 = 4)
		select @agent_type2 = 1 -- merge

	if @agent_type2 is not null 
	begin
		exec @retcode = sys.sp_MScheck_pull_access
				@agent_id = @agent_id,
				@agent_type = @agent_type2
		if @@error <> 0 or @retcode <> 0
			return (1)
	end
	else
	begin
		if is_member('db_owner') = 0
		begin
			RAISERROR (14126, 16, -1)
			return(1)
		end
	end

    select @publisher_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)
    select @subscriber_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@subscriber)
    
    select @publisher_database_id = id from MSpublisher_databases 
    where publisher_id = @publisher_id and publisher_db = @publisher_db

	select @article_id = article_id from MSrepl_commands
	where publisher_database_id = @publisher_database_id
	and xact_seqno = @xact_seqno
	and command_id = @command_id

	select @publication = mp.publication, @publication_id = mp.publication_id, @publication_type = mp.publication_type
	from dbo.MSpublications as mp, dbo.MSsubscriptions as ms
	where mp.publisher_id = ms.publisher_id
	and mp.publisher_db = ms.publisher_db
	and mp.publication_id = ms.publication_id
	and ms.publisher_id = @publisher_id
	and ms.publisher_db = @publisher_db
	and ms.subscriber_id = @subscriber_id
	and ms.subscriber_db = @subscriber_db
	and ms.article_id = @article_id

	select @article = article, @destination_object = destination_object, @source_object = source_object 
	from MSarticles
	where article_id = @article_id
		and publisher_id = @publisher_id
		and publisher_db = @publisher_db
		and publication_id = @publication_id

	 INSERT INTO msdb.dbo.sysreplicationalerts (status, agent_type , agent_id, error_id, alert_error_code, time, publisher,
								publisher_db, publication, publication_type, subscriber, subscriber_db,
								article, destination_object, source_object, alert_error_text)
				VALUES (0, @agent_type, @agent_id, @error_id, @alert_error_code, getdate(), @publisher, 
						@publisher_db, @publication, @publication_type, @subscriber, @subscriber_db, 
						@article, @destination_object, @source_object, @alert_error_text)
	
	IF @@ERROR <> 0
	BEGIN
	   RETURN (1)
	END

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_repl_alert] TO [public] AS [dbo]
GO
