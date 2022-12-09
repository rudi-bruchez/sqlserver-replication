SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_profile]
	@agent_id [int],
	@agent_type [int],
	@profile_name [sysname]
WITH EXECUTE AS CALLER
AS
declare @profile_id int
    declare @snapshot_type int
    declare @logreader_type int
    declare @distribution_type int
    declare @merge_type int
    declare @qreader_type int
    declare @retcode int

    select @snapshot_type = 1
    select @logreader_type = 2
    select @distribution_type = 3
    select @merge_type = 4
    select @qreader_type = 9

    -- Security check.  'db_owner', 'replmonitor', or in the PAL of any publication
    -- that makes use of this distribution database.
    exec @retcode = sys.sp_MSrepl_DistDBPALAccess
    if @retcode <> 0 or @@error <> 0
    BEGIN
        DECLARE @login sysname
        SET @login = suser_sname()
        RAISERROR(21672, 16, -1, @login) 
        return 1
    END

    select @profile_id = NULL

    if (@profile_name is not null) and (rtrim(ltrim(@profile_name)) <> '')
    begin
        select @profile_id = profile_id from msdb..MSagent_profiles where
            agent_type = @agent_type and profile_name = @profile_name

		/* raise error if profile not found */
		if (@profile_id is null)
		begin
			raiserror(21123, 16, -1, @profile_name)
			return (1)
		end
    end
    
    -- if profile name not specified, use default.
    if (@profile_id is null)
    begin
        if @agent_type = @snapshot_type 
        begin
            if @agent_id = 0
                select @profile_id = profile_id from msdb..MSagent_profiles where
                    agent_type = @agent_type and def_profile = 1
            else
                select @profile_id = profile_id from MSsnapshot_agents
                    where id = @agent_id
        end
        else if @agent_type = @logreader_type
        begin
            if @agent_id = 0
                select @profile_id = profile_id from msdb..MSagent_profiles where
                    agent_type = @agent_type and def_profile = 1
            else
                select @profile_id = profile_id from MSlogreader_agents
                    where id = @agent_id
        end
        else if @agent_type = @distribution_type
        begin
            if @agent_id = 0
                select @profile_id = profile_id from msdb..MSagent_profiles where
                    agent_type = @agent_type and def_profile = 1
            else
                select @profile_id = profile_id from MSdistribution_agents
                    where id = @agent_id
        end
        else if @agent_type = @merge_type
        begin
            if @agent_id = 0
                select @profile_id = profile_id from msdb..MSagent_profiles where
                    agent_type = @agent_type and def_profile = 1
            else
                select @profile_id = profile_id from dbo.MSmerge_agents
                    where id = @agent_id
        end
        else if @agent_type = @qreader_type
        begin
            if @agent_id = 0
                select @profile_id = profile_id from msdb..MSagent_profiles where
                    agent_type = @agent_type and def_profile = 1
            else
                select @profile_id = profile_id from MSqreader_agents
                    where id = @agent_id
        end
    end
    
    select profile_id, parameter_name, value 
        from msdb..MSagent_parameters
        where profile_id = @profile_id
GO
GRANT EXECUTE ON [sys].[sp_MShelp_profile] TO [public] AS [dbo]
GO
