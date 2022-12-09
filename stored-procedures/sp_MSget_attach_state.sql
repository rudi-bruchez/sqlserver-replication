SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_attach_state]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_attach_state] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_attach_state]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int

    --  Security Check
    --  We only run on subscriber so we only need sysadmin and dbo
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    
    -- For non independent agent publications
    if @publication is null or @publication = ''
        set @publication = 'ALL'

    select attach_state, attach_version from MSsubscription_agents
        where UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
            and subscription_type = @subscription_type
GO
GRANT EXECUTE ON [sys].[sp_MSget_attach_state] TO [public] AS [dbo]
GO
