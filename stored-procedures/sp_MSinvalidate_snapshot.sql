SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinvalidate_snapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinvalidate_snapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinvalidate_snapshot]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @publisher_id smallint  
	declare @automatic tinyint
	declare @virtual smallint 
	declare @retcode int
	declare @active tinyint
		, @initiated tinyint
		, @subscribed tinyint
	declare @publication_id int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	select @automatic = 1
	select @virtual = - 1
	select @active = 2
		, @initiated = 3
		, @subscribed = 1

	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Make sure publication exists
	select @publication_id = publication_id
		from dbo.MSpublications where publication = @publication and
		publisher_id = @publisher_id and publisher_db = @publisher_db

	-- Set the virtual subscription status to be 'subscribed' so that
	-- new subscription will wait for the next snapshot.
	update dbo.MSsubscriptions set status = @subscribed where 
		publication_id = @publication_id and
		sync_type = @automatic and
		status in (@active, @initiated) and
		subscriber_id = @virtual

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSinvalidate_snapshot] TO [public] AS [dbo]
GO
