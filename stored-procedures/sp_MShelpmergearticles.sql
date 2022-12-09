SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpmergearticles]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpmergearticles] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpmergearticles]
	@publication [sysname],
	@compatibility_level [int],
	@pubidin [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @pubid                  uniqueidentifier
    declare @artid                  uniqueidentifier
    declare @user_name              sysname
    declare @guid_col               sysname
    declare @identity_support       int
    declare @nickname               int
    declare @next_seed              bigint
    declare @objid                  int
    declare @qualname               nvarchar(270)
    declare @retcode                int
    declare @tablename              sysname
    declare @range                  bigint
    declare @threshold              int
    declare @db_name                sysname
    declare @has_joins              int
    declare @article_filter_category int
    declare @objid_looper           int
    declare @indexcol               int
    declare @rowcount1              int
    declare @rowcount2              int
    declare @use_partition_groups   smallint
    declare @maxschemaguidforarticle uniqueidentifier
        
    /*
    ** To public.
    */
    set nocount on
    if (@publication is null)
    begin
        RAISERROR(14003, 16, -1)
        return (1)
    end
        
    if object_id('MSmerge_contents') is NULL
    begin
        raiserror(20054, 16, -1)
        return (1)
    end
    
    select @db_name = db_name()

    if @pubidin is not NULL
        set @pubid = @pubidin
    else
        select @pubid = pubid from dbo.sysmergepublications
            where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=@db_name

    -- security check
    if (@pubid is null) or {fn ISPALUSER(@pubid)} <> 1
    begin
        RAISERROR (21423, 11, -1, @publication)
        return (1)
    end
    
    select @use_partition_groups = use_partition_groups from dbo.sysmergepublications where pubid = @pubid
    if @use_partition_groups is null
        select @use_partition_groups = 0

    if (@use_partition_groups <= 0) or (@compatibility_level < 9000000)
    begin
        exec @retcode = sys.sp_MShelpmergearticles_nonpartgroups @publication, @compatibility_level, @pubidin
        return @retcode
    end
    
    /* If the 7.0 merge agent is making this call then we need to make sure that the CLSID of the sp resolver is the old one and not the new one
       for an 8.0 merge agent we map CLSIDs from all resolvers it has in common with 9.0
       all this is done by calling fn_MSrepl_map_resolver_clsid */

    -- don't need compat level assume here that it is only called for 90+ compat level
    -- Note: Need to convert clsid in Katmai and above to Yukon as well since they are different. Hotfix#801802
    exec sys.sp_MShelpmergeselectarticles @pubid, @compatibility_level
        
    return (0)  
GO
GRANT EXECUTE ON [sys].[sp_MShelpmergearticles] TO [public] AS [dbo]
GO
