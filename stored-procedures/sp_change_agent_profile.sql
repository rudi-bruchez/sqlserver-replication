SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_change_agent_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_change_agent_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_change_agent_profile]
	@profile_id [int],
	@property [sysname],
	@value [nvarchar](3000)
WITH EXECUTE AS CALLER
AS
/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	IF lower(@property collate SQL_Latin1_General_CP1_CS_AS) not in ('description')
	BEGIN
		RAISERROR(21183, 16, -1, @property)
		RETURN (1)
	END

	IF exists ( select * from msdb..MSagent_profiles where profile_id = @profile_id)
	BEGIN
		update msdb..MSagent_profiles set description = @value where profile_id = @profile_id
		if @@error <> 0
			return(1)
	END
GO
GRANT EXECUTE ON [sys].[sp_change_agent_profile] TO [public] AS [dbo]
GO
