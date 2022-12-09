SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmaxsnapshottimestamp]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmaxsnapshottimestamp] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmaxsnapshottimestamp]
	@agent_id [int],
	@timestamp [timestamp] OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on
	
	declare @retcode 			tinyint

	-- this proc is called over the admin link
	if (is_srvrolemember('sysadmin') <> 1)
	begin
		raiserror (14126, 11, -1)
		return (1)
	end

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_MSgetmaxsnapshottimestamp', 'distribution')
		return 1
	end

	if @agent_id is NULL
	begin
		select @timestamp = max(timestamp) from MSsnapshot_history 
	end
	else
	begin
		select @timestamp = max(timestamp) from MSsnapshot_history where agent_id = @agent_id
	end

	if @timestamp is NULL
		select @timestamp = 0x00000
	
GO
GRANT EXECUTE ON [sys].[sp_MSgetmaxsnapshottimestamp] TO [public] AS [dbo]
GO
