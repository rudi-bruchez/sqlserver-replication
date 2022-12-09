SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_linkedservers_rowset]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_linkedservers_rowset] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_linkedservers_rowset]
	@srvname [sysname],
	@agent_id [int],
	@agent_type [int]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    
    -- Security check: sysadmin/dbo/PAL only
    exec @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id,
                                                @agent_type = @agent_type
    if @@error <> 0 or @retcode <> 0
        return 1

    SELECT    SVR_NAME            = srvname,
            SVR_PRODUCT            = srvproduct,
            SVR_PROVIDERNAME    = providername,
            SVR_DATASOURCE        = datasource,
            SVR_PROVIDERSTRING    = providerstring,
            SVR_LOCATION        = location,
            SVR_CATALOG            = catalog
    FROM    master.dbo.sysservers
    WHERE    UPPER(srvname) = UPPER(@srvname) collate database_default
      AND    ISNULL(providername,' ') <> ' '
      AND    ( ISNULL(datasource, ' ') <> ' '
                  or ISNULL(location, ' ') <> ' '
                  or ISNULL(providerstring, ' ') <> ' '
                  or ISNULL(catalog, ' ') <> ' '
              )
    ORDER BY 1

    if @@error <> 0
        return 1
    else
        return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_linkedservers_rowset] TO [public] AS [dbo]
GO
