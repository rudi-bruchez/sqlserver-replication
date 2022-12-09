SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdatelastsyncinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdatelastsyncinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdatelastsyncinfo]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int],
	@last_sync_status [int],
	@last_sync_summary [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    declare @db_id int

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    if object_id('dbo.MSsubscription_agents') is null
        return(1)

    -- For non independent agent publications
    if @publication is null or @publication = ''
        set @publication = 'ALL'

    if not exists (select * from MSsubscription_agents where
            UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
            and subscription_type = @subscription_type)
    begin
        exec sys.sp_MSinit_subscription_agent
            @publisher,
            @publisher_db,
            @publication,
            @subscription_type
    end

    update MSsubscription_agents set     
        last_sync_time = getdate(), 
        last_sync_status = @last_sync_status, 
        last_sync_summary = @last_sync_summary
        where UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
            and subscription_type = @subscription_type

    set @db_id = db_id()

    exec sys.sp_repl_generate_sync_status_event
        @syncstatus = @last_sync_status,
        @db_id = @db_id,
        @syncsummary = @last_sync_summary

    update MSreplication_subscriptions set
        time = convert(smalldatetime, getdate()) 
    WHERE UPPER(publisher) = UPPER(@publisher) AND
        publisher_db  = @publisher_db AND
        ((@publication = N'ALL' and independent_agent = 0) or 
        @publication = publication) and
        subscription_type = @subscription_type
GO
GRANT EXECUTE ON [sys].[sp_MSupdatelastsyncinfo] TO [public] AS [dbo]
GO
