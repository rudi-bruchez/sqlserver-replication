SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_raiserror]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_raiserror] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_raiserror]
	@agent [sysname],
	@agent_name [nvarchar](100),
	@status [int],
	@message [nvarchar](255),
	@subscriber [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
	if @status = 2      --Succeeded
		raiserror (14150, 10, -1, @agent, @agent_name, @message)
	else if @status = 5 --Retry Failure
		raiserror (14152, 10, -1, @agent, @agent_name, @message)
	else if @status = 6 --Failure
	begin
		-- @agent_name is null when the agent record has not been initialized
		-- yet (the error occured during initialization). Display appropriate
		-- message.
		if @agent_name is null 
		begin
			raiserror (14173, 18, -1, @agent, @message)
		end
		else
		begin
			raiserror (14151, 18, -1, @agent, @agent_name, @message)
		end
	end
	else if @status = 7
	begin
		raiserror (20574, 10, -1, @subscriber, @article, @publication)
	end
	else if @status = 8
	begin
		raiserror (20575, 10, -1, @subscriber, @article, @publication)
	end
	else if @status = 9
	begin
		raiserror (14158, 10, -1, @agent, @agent_name, @message)
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_raiserror] TO [public] AS [dbo]
GO
