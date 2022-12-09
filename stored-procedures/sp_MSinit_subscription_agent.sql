SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinit_subscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinit_subscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinit_subscription_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    declare @login_time datetime

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
    RETURN(1)

    -- For non independent agent publications
    if @publication is null or @publication = ''
        set @publication = 'ALL'

        select @login_time = login_time from sys.sysprocesses where spid = @@spid

    if not exists (select * from MSsubscription_agents where
            UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
            and subscription_type = @subscription_type)
    begin
        INSERT INTO MSsubscription_agents
            (publisher, publisher_db, publication, subscription_type,
             queue_id, update_mode, failover_mode, spid, login_time )
        values (UPPER(@publisher), @publisher_db, @publication, @subscription_type, 
            null, 1, 0, @@spid, @login_time)
    end
    else
    begin
        -- It is possible that 2 instance of the distribution agent do this update at 
        -- the same time. One will fail later at the instance check at the distributor
        -- side. We no longer use the spid and login_time column anywhere else. 
        update MSsubscription_agents set      
            spid = @@spid,
            login_time = @login_time
            where UPPER(publisher) = UPPER(@publisher)
                and publisher_db =  @publisher_db
                and publication = @publication
                and subscription_type = @subscription_type
    end
GO
GRANT EXECUTE ON [sys].[sp_MSinit_subscription_agent] TO [public] AS [dbo]
GO
