SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_replmergealert]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_replmergealert] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_replmergealert]
	@agent_type [int],
	@agent_id [int],
	@error_id [int],
	@alert_error_code [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@article [sysname],
	@destination_object [sysname],
	@source_object [sysname],
	@alert_error_text [nvarchar](max)
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	
	SET NOCOUNT ON

	exec @retcode = sys.sp_MScheck_pull_access
			@agent_id = @agent_id,
			@agent_type = 1 -- merge agent
	if @@error <> 0 or @retcode <> 0
		return (1)

	INSERT INTO msdb.dbo.sysreplicationalerts (status, agent_type , agent_id, error_id, alert_error_code, time, publisher,
								publisher_db, publication, publication_type, subscriber, subscriber_db,
								article, destination_object, source_object, alert_error_text)
				VALUES (0, @agent_type, @agent_id, @error_id, @alert_error_code, getdate(), @publisher, 
						@publisher_db, @publication, @publication_type, @subscriber, @subscriber_db, 
						@article, @destination_object, @source_object, @alert_error_text)
	
	IF @@ERROR <> 0
	BEGIN
	   RETURN (1)
	END

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_replmergealert] TO [public] AS [dbo]
GO
