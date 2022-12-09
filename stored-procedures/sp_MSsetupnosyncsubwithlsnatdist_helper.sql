SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetupnosyncsubwithlsnatdist_helper]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist_helper] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist_helper]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@subscriptionlsn [binary](10),
	@lsnsource [int],
	@pubid [int],
	@publisher_db_version [int],
	@script_txt [nvarchar](max),
	@nosync_setup_script [nvarchar](max),
	@next_valid_lsn [binary](10),
	@artid [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin 
	set nocount on
	declare @publisherid int,
			@subscriberid int,
			@publisher_database_id int,
			@publication_id int,
			@nosyncCommandStr nvarchar(max)

	-- Security check 
	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror(21089, 16, -1)
		return 1
	end

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

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

	-- Obtain artid if this is for an incremental article
	-- or one of the artids if @article equals to N'all'.
	select @artid = article_id    
	from MSarticles
	where publisher_id = @publisherid
	   and publisher_db = @publisher_db 
	   and publication_id = @publication_id
	   and (@article = N'all' or article = @article)
	if @@error<>0 or @artid is NULL goto Failure

	begin tran nosyncSubSetupHelper
	save tran nosyncSubSetupHelper

	-- Activate subscriptions in dbo.MSsubscriptions
	update dbo.MSsubscriptions
	   set status = 2 --active status
	 where publisher_database_id = @publisher_database_id
	   and publisher_id = @publisherid
	   and publisher_db = @publisher_db -- Extra insurance
	   and publication_id = @publication_id
	   and subscriber_id = @subscriberid
	   and subscriber_db = @destination_db
	   and (@article = N'all' or article_id = @artid)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	-- The table MSnosyncsubsetup should already exist
	-- in distribution database.
	if object_id(N'dbo.MSnosyncsubsetup', 'U') is NULL 
		goto nosyncSubSetupHelperFailure

	-- Try to clean up the table before adding parameters (rows)
	-- into the table for the specified nonsync subscription.
	-- Note that, in MSnosyncsubsetup table, we need the publication 
	-- id (i.e., @publid) from publisher db instead of the publication
	-- id (i.e., MSpublications.publication_id) from distribution db, 
	-- which might be different.
	delete dbo.MSnosyncsubsetup 
	where publisher_database_id = @publisher_database_id
	  and publication_id = @pubid
	  and artid = @artid
	  and next_valid_lsn = @next_valid_lsn
	if @@error<>0 goto nosyncSubSetupHelperFailure

	-- Update table MSnosyncsubsetup with the parameters
	-- to be needed by stored proc sp_MSsetupnosyncsubwithlsnatdist
	declare @parameterValueStr nvarchar(max)
	select @parameterValueStr = @publisher
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'publisher',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = @publisher_db
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'publisher_db',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = @publication
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'publication',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = @article
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'article',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(@subscriber, N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'subscriber',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(@destination_db, N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'destination_db',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(CAST(@subscriptionlsn AS nvarchar(max)), N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'subscriptionlsn',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(CAST(@lsnsource AS nvarchar(20)), N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'lsnsource',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(CAST(@pubid AS nvarchar(20)), N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'originator_publication_id',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(CAST(@publisher_db_version AS nvarchar(20)), N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'originator_db_version',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(@script_txt, N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'originator_meta_data',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(@nosync_setup_script, N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'nosync_setup_script',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	select @parameterValueStr = ISNULL(CAST(@next_valid_lsn AS nvarchar(max)), N'')
	insert into dbo.MSnosyncsubsetup ( 
		publisher_database_id,
		publication_id,
		artid,
		next_valid_lsn,
		parameterName,
		parameterValue)
	values (
		@publisher_database_id,
		@pubid,
		@artid,
		@next_valid_lsn,
		N'next_valid_lsn',
		@parameterValueStr)
	if @@error<>0 goto nosyncSubSetupHelperFailure

	commit tran nosyncSubSetupHelper
	return 0

nosyncSubSetupHelperFailure:
	rollback tran nosyncSubSetupHelper
	commit tran
	return 1

Failure:
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetupnosyncsubwithlsnatdist_helper] TO [public] AS [dbo]
GO
