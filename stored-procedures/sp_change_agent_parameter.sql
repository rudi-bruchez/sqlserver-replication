SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_change_agent_parameter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_change_agent_parameter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_change_agent_parameter]
	@profile_id [int],
	@parameter_name [sysname],
	@parameter_value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @slash_parameter_name sysname
	declare @dash_parameter_name sysname
	declare @retcode int
	declare @agent_type int
	declare @logreader_type int
	declare @distribution_type int

  select @logreader_type = 2
	,@distribution_type = 3

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	select @parameter_name = LTRIM(RTRIM(@parameter_name))
	select @parameter_value = LTRIM(RTRIM(@parameter_value))

	-- DMO sends in empty sting as '(null)'.
	if @parameter_value = N'(null)'
		select @parameter_value = N''

	-- Append leading '-' when not given
	if (substring(@parameter_name, 1, 1) <> '/' and 
		substring(@parameter_name, 1, 1) <> '-')
	BEGIN
		select @parameter_name = N'-' + @parameter_name
	END

	-- Call proc to validate parameter value
	exec @retcode = sys.sp_MSvalidate_agent_parameter 
						@profile_id = @profile_id, 
						@parameter_name = @parameter_name,
						@parameter_value = @parameter_value
	if @retcode <> 0
		RETURN(1)


	select @slash_parameter_name = lower(stuff(@parameter_name, 1, 1, N'/') collate SQL_Latin1_General_CP1_CS_AS)
	select @dash_parameter_name = lower(stuff(@parameter_name, 1, 1, N'-') collate SQL_Latin1_General_CP1_CS_AS)
   
	IF exists ( select * from msdb..MSagent_parameters 
			where profile_id = @profile_id and 
				(lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @slash_parameter_name collate SQL_Latin1_General_CP1_CS_AS or
				 lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @dash_parameter_name collate SQL_Latin1_General_CP1_CS_AS))
	BEGIN
		update msdb..MSagent_parameters set value = @parameter_value where 
			profile_id = @profile_id and 
			(lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @slash_parameter_name collate SQL_Latin1_General_CP1_CS_AS or
			lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @dash_parameter_name collate SQL_Latin1_General_CP1_CS_AS) 

		if @@error <> 0
			return(1)
		else
		begin
			select @agent_type = agent_type from msdb..MSagent_profiles
				where profile_id = @profile_id

			if (@agent_type is not null and
				((@agent_type = @logreader_type and @parameter_name in (N'-Output', N'-OutputVerboseLevel', N'-PollingInterval', N'-ReadBatchSize', N'-ReadBatchThreshold'))
				or (@agent_type = @distribution_type and @parameter_name in (N'-CommitBatchSize', N'-CommitBatchThreshold', N'-MaxDeliveredTransactions', N'-Output', N'-OutputVerboseLevel', N'-PollingInterval', N'-SubscriptionStreams'))))
				
				RAISERROR (20094, 10, -1, @parameter_name)--Profile parameter '%s' is dynamically reloadable and the change will be applied to running agents within configured period of time.
		end
	END
GO
GRANT EXECUTE ON [sys].[sp_change_agent_parameter] TO [public] AS [dbo]
GO
