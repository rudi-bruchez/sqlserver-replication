SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScache_agent_parameter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScache_agent_parameter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScache_agent_parameter]
	@profile_name [sysname],
	@parameter_name [sysname],
	@parameter_value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @slash_parameter_name sysname
	declare @dash_parameter_name sysname
	declare @retcode int

	--
	-- security check
	--
	exec @retcode = sys.sp_MSreplcheck_subscribe
	if @@ERROR <> 0 or @retcode <> 0
	begin
		return(1)
	end
	
	select @parameter_name = LTRIM(RTRIM(@parameter_name))
	select @parameter_value = LTRIM(RTRIM(@parameter_value))

	-- Append leading '-' when not given
	if (substring(@parameter_name, 1, 1) <> '/' and 
		substring(@parameter_name, 1, 1) <> '-')
	BEGIN
		select @parameter_name = N'-' + @parameter_name
	END

	select @slash_parameter_name = lower(stuff(@parameter_name, 1, 1, N'/') collate SQL_Latin1_General_CP1_CS_AS)
	select @dash_parameter_name = lower(stuff(@parameter_name, 1, 1, N'-') collate SQL_Latin1_General_CP1_CS_AS)

	IF exists ( select * from dbo.MSmerge_agent_parameters 
			where profile_name = @profile_name and 
				(lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @slash_parameter_name collate SQL_Latin1_General_CP1_CS_AS or
				 lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @dash_parameter_name collate SQL_Latin1_General_CP1_CS_AS))
	BEGIN
		update dbo.MSmerge_agent_parameters set value = @parameter_value where 
			profile_name = @profile_name and 
			(lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @slash_parameter_name collate SQL_Latin1_General_CP1_CS_AS or
			lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS) = @dash_parameter_name collate SQL_Latin1_General_CP1_CS_AS) 

		if @@error <> 0
			return(1)
	END
	ELSE
	BEGIN
		insert into dbo.MSmerge_agent_parameters values (@profile_name, @parameter_name, @parameter_value) ;
		if @@error <> 0
			return(1)
	END
GO
GRANT EXECUTE ON [sys].[sp_MScache_agent_parameter] TO [public] AS [dbo]
GO
