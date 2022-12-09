SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_subscription_seqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_subscription_seqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_subscription_seqno]
	@agent_id [int],
	@get_snapshot [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publication_id int
	declare @sub_agent_id int
	declare @virtual_anonymous smallint
	declare @virtual smallint
	declare @retcode int
	declare @automatic tinyint

	select @automatic = 1
	select @virtual = -1
	select @virtual_anonymous = -2

	-- Security Check
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_id = @agent_id,
		@agent_type = 0 -- distribution agent
	if @@error <> 0 or @retcode <> 0
		return (1)

	-- Get version agent_id
	select top 1 @sub_agent_id = s2.agent_id from dbo.MSsubscriptions s1,
		MSsubscriptions s2 where
		s1.publisher_id = s2.publisher_id and
		s1.publisher_db = s2.publisher_db and
		s1.publication_id = s2.publication_id and
		s1.agent_id = @agent_id and
		s2.subscriber_id = 
			case @get_snapshot when 0 
				then @virtual_anonymous
				else @virtual
			end 
	
	-- If there are no virtual subscriptions defined. Don't reset.
	-- This might happen when the distribution agent tries to 
	-- reset an subscription on a non immediate_sync publication 
	-- (this can
	-- only happen when the publication is changed from immediate_sync to non
	-- immdiate_sync after the distribution agent has queried the immediate_sync
	-- property)
	if @sub_agent_id = 0
		return 0

	-- 'no_sync' subscriptions are handled differently
	if exists (select * from dbo.MSsubscriptions where agent_id = @agent_id and 
		sync_type <> @automatic)
	begin
		-- If @get_snapshot = 0, the distribution agent is process the attached
		-- subscription for the first time. Set subscription_seqno to zero so that
		-- all changes that are not in the subscription copy will be picked up.
		-- Otherwise, do noting.
		if @get_snapshot = 0
		begin
			update dbo.MSsubscriptions  set 
				-- Use current date rather than virtual sub date for the
				-- calculation in cleanup 
				subscription_time = getdate(),
				-- lsn should be ten bytes long. We will not be here
				-- if the publisher is 6.x since 6x publisher does not
				-- support immediate_sync (thus does not support subscription copy as well)
				subscription_seqno = 0x00000000000000000000,
				publisher_seqno = 0x00000000000000000000,
				ss_cplt_seqno = 0x00000000000000000000
				from dbo.MSsubscriptions rs1 where
					agent_id = @agent_id 
		end		
		return 0
	end

	-- Reset the subscription statue to be that of the virtual_anonymous subscription.
	-- Thus, only the snapshot transactions that are later than the subscriber transaction
	-- timestamp will be picked up (i.e., new article or schema change article.)
	update dbo.MSsubscriptions  set 
		snapshot_seqno_flag =  
			(select snapshot_seqno_flag from dbo.MSsubscriptions rs2
				where
				rs2.agent_id = @sub_agent_id and
				rs2.article_id = rs1.article_id),
		status =    
			(select status from dbo.MSsubscriptions rs2
				where
				rs2.agent_id = @sub_agent_id and
				rs2.article_id = rs1.article_id),
		-- Use current date rather than virtual sub date for the
		-- calculation in cleanup 
		subscription_time = getdate(),
		subscription_seqno = 
			(select subscription_seqno from dbo.MSsubscriptions rs2
				where
				rs2.agent_id = @sub_agent_id and
				rs2.article_id = rs1.article_id),
		publisher_seqno = 
			(select publisher_seqno from dbo.MSsubscriptions rs2
				where
				rs2.agent_id = @sub_agent_id and
				rs2.article_id = rs1.article_id),
		ss_cplt_seqno = 
			(select ss_cplt_seqno from dbo.MSsubscriptions rs2
				where
				rs2.agent_id = @sub_agent_id and
				rs2.article_id = rs1.article_id)
		from dbo.MSsubscriptions rs1 where
			agent_id = @agent_id
		
	if @@ERROR <> 0
		return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSreset_subscription_seqno] TO [public] AS [dbo]
GO
