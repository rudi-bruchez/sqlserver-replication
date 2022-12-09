SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelptracertokens]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelptracertokens] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelptracertokens]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare @retcode			int,
			@publication_id		int,
			@distribution_db	sysname
	
	select @distribution_db = db_name()
	
	--
	-- security check.
	-- User must be member of 'replmonitor' role in distribution database
	--
	exec @retcode = sys.sp_MSrepl_DistributorReplMonitorAccess @distribution_db = @distribution_db
	if @retcode != 0 or @@error != 0
		return 1

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (@distribution_db) != 1
	begin
		-- sp_MSispeertopeeragent can only be executed in the distribution database.
		raiserror (21482, 16, -1, 'sp_MShelptracertokens', 'distribution')
		return 1
	end
	
	-- check to see if the publication exists
	select @publication_id = msp.publication_id
		from dbo.MSpublications msp
			join MSreplservers ss
				on msp.publisher_id = ss.srvid
		where UPPER(ss.srvname) = UPPER(@publisher)
			and msp.publisher_db = @publisher_db
			and msp.publication = @publication
						
	if @publication_id is NULL
	begin
		-- Publication 'publication' does not exist.
		raiserror(21200, 16, -1, @publication)
		return 1
	end

	-- make sure to only return the tracer_ids 
	-- that have tracer history information.
	select tracer_id,
			publisher_commit
		from MStracer_tokens
		where publication_id = @publication_id
			and tracer_id in (select parent_tracer_id
									from MStracer_history)
		order by publisher_commit desc

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MShelptracertokens] TO [public] AS [dbo]
GO
