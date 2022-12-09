SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changelogreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changelogreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changelogreader_agent]
	@job_login [nvarchar](257),
	@job_password [sysname],
	@publisher_security_mode [smallint],
	@publisher_login [sysname],
	@publisher_password [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname
	
	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@publisher_type = @publisher_type OUTPUT,
													@rpcheader		= @cmd OUTPUT

	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_changelogreader_agent'

	EXEC @retcode = @cmd
					@job_login					= @job_login,
					@job_password				= @job_password,
					@publisher_security_mode	= @publisher_security_mode,
					@publisher_login			= @publisher_login,
					@publisher_password 		= @publisher_password,
					@publisher					= @publisher,
					@publisher_type 			= @publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_changelogreader_agent] TO [public] AS [dbo]
GO
