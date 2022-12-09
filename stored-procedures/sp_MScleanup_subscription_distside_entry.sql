SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanup_subscription_distside_entry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanup_subscription_distside_entry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanup_subscription_distside_entry]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin

	declare @min_valid_day 		datetime
	, @publisher_id 		int
	, @publication_id		int
	, @retention 			int
	, @agent_id			int
	, @retcode int
	, @retention_period_unit tinyint

	-- Security Check: require sysadmin/dbo of dist 
	IF IS_MEMBER('db_owner') != 1
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MScleanup_subscription_distside_entry', 'distribution')
		RETURN 1
	END

    select @publisher_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher) 
    if @publisher_id is NULL
        return 0
        
    select @publication_id = publication_id, @retention = retention, @retention_period_unit = retention_period_unit
        from dbo.MSpublications
        where publisher_id = @publisher_id
        and publisher_db = @publisher_db
        and publication = @publication
        and publication_type = 2
        and retention<>0
        
    if @publication_id is null
        return 0

	select @min_valid_day = sys.fn_add_units_to_date(-@retention, @retention_period_unit, getdate())

	select @agent_id = msa.id from dbo.MSmerge_agents msa
	where msa.creation_date < @min_valid_day
	and msa.publisher_id = @publisher_id
	and msa.publisher_db = @publisher_db
	and msa.publication = @publication   
	and upper(msa.subscriber_name) = upper(@subscriber) collate database_default
	and msa.subscriber_db = @subscriber_db
	   
	if @agent_id is not null and not exists (
												select * from dbo.MSmerge_sessions sess
												where sess.agent_id = @agent_id
												and sess.end_time > @min_valid_day
											)
	begin
		exec @retcode = sys.sp_MSdrop_merge_agentid @agent_id
		if @retcode <> 0 or @@error <> 0
			return 1
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MScleanup_subscription_distside_entry] TO [public] AS [dbo]
GO
