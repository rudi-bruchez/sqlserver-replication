SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_stopmergepushsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_stopmergepushsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_stopmergepushsubscription_agent]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	declare @stop tinyint
	set @retcode = 0
	set @stop = 1

	exec @retcode = sys.sp_MSmergepushsubscriptionagentjobcontrol
		@publication = @publication,
		@subscriber = @subscriber,
		@subscriber_db = @subscriber_db,
		@action = @stop
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_stopmergepushsubscription_agent] TO [public] AS [dbo]
GO
