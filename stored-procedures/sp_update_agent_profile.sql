SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_update_agent_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_update_agent_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_update_agent_profile]
	@agent_type [int],
	@agent_id [int],
	@profile_id [int]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	DECLARE @proc               nvarchar(255)

	DECLARE @snapshot_type          int
	DECLARE @logreader_type         int
	DECLARE @distribution_type      int
	DECLARE @merge_type         int
	DECLARE	@qreader_type			int
	DECLARE @profile_name			sysname

	SELECT @snapshot_type = 1
	SELECT @logreader_type = 2
	SELECT @distribution_type = 3
	SELECT @merge_type = 4
	SELECT @qreader_type = 9
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_update_agent_profile', 'distribution')
		return (1)
	end

	IF @agent_type NOT IN (@snapshot_type, @logreader_type, @distribution_type, @merge_type, @qreader_type)
		RETURN (1) 

	/* The profile must be defined for the agent type in MSagent_profiles table */
	IF NOT EXISTS ( select * from msdb..MSagent_profiles
			where profile_id = @profile_id
			and agent_type = @agent_type )
		RETURN (1)
	
	-- The system 'SkipErrors' profile is for sql subscribers only.
	if @distribution_type = @agent_type and @profile_id = 14
	begin
		declare @subscriber_id int, @publisher_id int
		select top 1 @publisher_id = publisher_id, @subscriber_id = subscriber_id from
			MSsubscriptions where agent_id = @agent_id
		declare @subscriber sysname, @publisher sysname
		select @publisher = srvname from MSreplservers where srvid = @publisher_id
		select @subscriber = srvname from MSreplservers where srvid = @subscriber_id

		-- Use 'exists' not 'not exists' to take care null @publisher or @subscriber
		if exists (select * from MSsubscriber_info where
			upper(publisher) = upper(@publisher) and
			upper(subscriber) = upper(@subscriber) and
			type <> 0)
		begin
			raiserror(20603, 16, -1)
			return 1
		end
	end
	
	SELECT @proc = 'UPDATE ' +
		CASE @agent_type
		   WHEN @snapshot_type THEN 'MSsnapshot_agents'
		   WHEN @logreader_type THEN 'MSlogreader_agents'
		   WHEN @distribution_type THEN 'MSdistribution_agents'
		   WHEN @merge_type THEN 'MSmerge_agents'
		   WHEN @qreader_type THEN 'MSqreader_agents'
		END
		+ ' SET profile_id = ' + convert(nvarchar(10), @profile_id)
		+ ' WHERE id = ' + convert(nvarchar(10), @agent_id)

	EXECUTE (@proc)

	IF @@ERROR <> 0 
		RETURN (1)
	ELSE
	BEGIN
		IF @agent_type IN (@logreader_type, @distribution_type)
		BEGIN
			SELECT @profile_name = profile_name FROM msdb..MSagent_profiles
				WHERE profile_id = @profile_id
				AND agent_type = @agent_type

			IF(@profile_name is not null)
				RAISERROR (20095, 10, -1, @profile_name)--For agent profile '%s', parameters marked as is_reloadable in msdb.dbo.MSagentparameterlist table will be applied to running agents within configured period of time.
		END
	END
end
GO
GRANT EXECUTE ON [sys].[sp_update_agent_profile] TO [public] AS [dbo]
GO
