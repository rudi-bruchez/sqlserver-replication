SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_get_job_status_mergesubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_get_job_status_mergesubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_get_job_status_mergesubscription_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@agent_name [nvarchar](100)
WITH EXECUTE AS CALLER
AS
begin	
	set nocount on
	declare @retcode  int
	declare @isdistdb bit	
	declare @runstatus int  
	
	select @isdistdb = sys.fn_MSrepl_isdistdb(DB_NAME())

	--
    -- security check
    --
	if (@isdistdb = 1)
	begin
		if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
		begin
			raiserror(14260, 16, -1)
			return (1)
		end
	end
	else
	begin
		if not (is_member(N'db_owner') = 1)
		begin
			raiserror(14260, 16, -1)
			return (1)
		end
	end


	
	    
    if @isdistdb = 1 and @agent_name is null
    begin
		raiserror(14043, 16, -1, '@agent_name', 'sp_get_job_status_mergesubscription_agent')
		return 1
	end
	else if @isdistdb = 0 and (@publisher is null or @publisher_db is null or @publication is null)
    begin
		-- subscriber-side monitoring
		if @publisher is null
			raiserror(14043, 16, -1, '@publisher', 'sp_get_job_status_mergesubscription_agent')
		if @publisher_db is null
			raiserror(14043, 16, -1, '@publisher_db', 'sp_get_job_status_mergesubscription_agent')
		if @publication is null
			raiserror(14043, 16, -1, '@publication', 'sp_get_job_status_mergesubscription_agent')
		return 1
	end	

	if(@isdistdb = 1)
	begin
		exec @retcode = sp_get_job_status_mergepushsubscription_agent @agent_name,@runstatus=@runstatus output 
	end	
	else
	begin
		exec @retcode = sp_get_job_status_mergepullsubscription_agent 
					   @publisher=@publisher,
					   @publisher_db=@publisher_db,
					   @publication=@publication,
					   @runstatus=@runstatus output 
	end

	select @runstatus

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_get_job_status_mergesubscription_agent] TO [public] AS [dbo]
GO
