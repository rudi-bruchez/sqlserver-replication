SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropanonymoussubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropanonymoussubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropanonymoussubscription]
	@agent_id [int],
	@type [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	if @type not in (1,2)
	begin
		raiserror(20587, 16, -1, '@type', 'sp_dropanonymoussubscription')
		return (1)
	end
	-- If tran
	if @type = 1
	begin
		if not exists (select * from MSdistribution_agents where
			id = @agent_id and
			subscriber_name is not null)
		begin
			RAISERROR (14055, 11, -1)
			return(1)
		end
		exec @retcode = sys.sp_MSdrop_distribution_agentid @agent_id
		if @retcode <> 0 or @@error <> 0
			return 1
	end
	else
	begin
		if not exists (select * from dbo.MSmerge_agents where
			id = @agent_id and
			anonymous_subid is not null)
		begin
			RAISERROR (14055, 11, -1)
			return(1)
		end
		exec @retcode = sys.sp_MSdrop_merge_agentid @agent_id
		if @retcode <> 0 or @@error <> 0
			return 1
	end
end
GO
GRANT EXECUTE ON [sys].[sp_dropanonymoussubscription] TO [public] AS [dbo]
GO
