SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_subscription_rowset]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_subscription_rowset] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_subscription_rowset]
	@subscriber [sysname],
	@agent_id [int],
	@agent_type [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode int
	DECLARE @subscriber_provider sysname
	
	SELECT @subscriber_provider = NULL
	
	-- Security check: sysadmin/dbo/PAL only
	EXEC @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id,
												@agent_type = @agent_type
	IF @@error <> 0 or @retcode <> 0
		RETURN 1
		
	-- Query the MSdistribution_agents entry for the subscriber provider
    SELECT  @subscriber_provider = ma.subscriber_provider
    FROM    MSdistribution_agents ma, MSreplservers ss
    WHERE    UPPER(ss.srvname) = UPPER(@subscriber) collate database_default
      AND    ma.subscriber_id = ss.srvid
      AND    ma.id = @agent_id

	IF @@error <> 0
		RETURN 1
	
	-- If the subscriber_provider from the MSdistribution_agents table is     
	-- NULL, we either have a downlevel publisher, or yukon security is not
	-- enabled.  In both cases, we need to call sp_MSrepl_linkedserver_rowset
	-- to generate the rowset.
	IF ISNULL(@subscriber_provider, N' ') = N' '
	BEGIN
		exec @retcode = sys.sp_MSrepl_linkedservers_rowset @srvname = @subscriber,
														  @agent_id = @agent_id,
														  @agent_type = @agent_type
		IF @@error <> 0 or @retcode <> 0
		BEGIN
			RETURN 1
		END
			
		RETURN 0	
			
	END 

	-- Query the MSdistribution_agents entry for the subscriber information
    SELECT  SUB_NAME            = msssrs.msrs_srvname,
            SUB_PRODUCT         = msssrs.srvproduct,
            SUB_PROVIDERNAME    = ma.subscriber_provider,
            SUB_DATASOURCE      = ma.subscriber_datasrc,
            SUB_PROVIDERSTRING  = ma.subscriber_provider_string,
            SUB_LOCATION        = ma.subscriber_location,
            SUB_CATALOG         = ma.subscriber_catalog
    FROM    MSdistribution_agents ma, MSsysservers_replservers msssrs
    WHERE    UPPER(msssrs.msrs_srvname) = UPPER(@subscriber) collate database_default
      AND    ma.subscriber_id = msssrs.msrs_srvid
      AND    ma.id = @agent_id

	IF @@error <> 0
	BEGIN
		RETURN 1
	END    
											   
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_subscription_rowset] TO [public] AS [dbo]
GO
