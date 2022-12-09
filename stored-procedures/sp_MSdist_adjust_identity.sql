SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdist_adjust_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdist_adjust_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdist_adjust_identity]
	@agent_id [int],
	@tablename [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @publisher sysname
	declare @publisher_db sysname
	declare @publisher_id smallint
	declare @publication sysname
	declare @next_seed bigint
	declare @range bigint
	declare @threshold int
	declare @retcode int

	-- Security check.
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_id = @agent_id,
		@agent_type = 0 -- distribution agent
	if @@error <> 0 or @retcode <> 0
		return (1)

	select @publication = publication, @publisher_id = publisher_id,
		@publisher_db = publisher_db from MSdistribution_agents where
		id = @agent_id

	select @publisher = srvname from MSreplservers where 
		srvid = @publisher_id
	-- Get the publication id.
	-- Note: auto identity range is only supported for queued tran pub
	-- which implies independent agent.
	declare @publication_id int
	select @publication_id = publication_id from dbo.MSpublications	where
		publication =  @publication and
		publisher_id = @publisher_id and
		publisher_db = @publisher_db

	-- Get the source object name
	declare @src_object sysname
	select @src_object = source_object from MSarticles where
		publication_id = @publication_id and
		destination_object = @tablename

	if @src_object is not null
	begin
		exec @retcode = sys.sp_MSfetchAdjustidentityrange
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@tablename = @src_object,
			@adjust_only = 1,
			@for_publisher = 0,
			@next_seed = @next_seed output,
			@range = @range output,
			@threshold = @threshold output
		if @@error <> 0 or @retcode <> 0
			return 1
	end

	-- Return nothing if the table is not found in the table collection served by
	-- the distribution agent.
	select 'next_seed' = @next_seed, 'range' = @range, 'threshold' = @threshold
		where @next_seed is not null 
end
GO
GRANT EXECUTE ON [sys].[sp_MSdist_adjust_identity] TO [public] AS [dbo]
GO
