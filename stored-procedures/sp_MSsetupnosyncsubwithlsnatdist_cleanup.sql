SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetupnosyncsubwithlsnatdist_cleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist_cleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist_cleanup]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@artid [int],
	@subscriber [sysname],
	@destination_db [sysname],
	@next_valid_lsn [binary](10)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @publisherid int,
			@subscriberid int,
			@publisher_database_id int,
			@publication_id int

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	-- Security check 
	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror(21089, 16, -1)
		return 1
	end

    -- Obtain Publisher's server id
    select @publisherid = srvid 
      from MSreplservers
     where upper(srvname) = upper(@publisher) collate database_default
    if @@error<>0 goto Failure

    -- Obtain Subscriber's server id
    select @subscriberid = srvid
      from MSreplservers
     where upper(srvname) = upper(@subscriber) collate database_default
    if @@error<>0 goto Failure
            
    -- Find out what the publisher database id is
    select @publisher_database_id = id
      from dbo.MSpublisher_databases
     where publisher_db = @publisher_db
       and publisher_id = @publisherid
    if @@error<>0 goto Failure

	-- Obtain the publication id
	select @publication_id = publication_id
	  from dbo.MSpublications
	 where publisher_id = @publisherid
	   and publisher_db = @publisher_db
	   and publication = @publication
	if @@error<>0 goto Failure

	-- Deactivate subscriptions in dbo.MSsubscriptions
	update dbo.MSsubscriptions
	   set status = 0 --inactive status
	 where publisher_database_id = @publisher_database_id
	   and publisher_id = @publisherid
	   and publisher_db = @publisher_db
	   and publication_id = @publication_id
	   and subscriber_id = @subscriberid
	   and subscriber_db = @destination_db
	   and (@article = N'all' or article_id = @artid)
	if @@error<>0 goto Failure

	-- Delete the rows from MSnosyncsubsetup table regarding 
	-- the specified nonsync subscription; we do not remove 
	-- the table itself since it might be useful for future
	-- non-sync subscription.
	if object_id(N'dbo.MSnosyncsubsetup', 'U') is NOT NULL
	begin
		delete dbo.MSnosyncsubsetup 
		where publisher_database_id = @publisher_database_id
		  and publication_id = @publication_id
		  and artid = @artid
		  and next_valid_lsn = @next_valid_lsn
	end
	if @@error<>0 goto Failure

	return 0

Failure:
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetupnosyncsubwithlsnatdist_cleanup] TO [public] AS [dbo]
GO
