SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_enumcustomresolvers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_enumcustomresolvers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_enumcustomresolvers]
	@distributor [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @distribution_db sysname
    declare @distproc nvarchar(1000)
    declare @retcode int
    declare @regkey nvarchar(260)
    declare @stmt     nvarchar(1000)

    select @retcode = 0
 
    /*
    ** Security Check.
    ** Only the dbo needs to call this procedure
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Get the distributor 
    */
    EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT, @distribdb = @distribution_db OUTPUT
    IF @@error <> 0 OR @retcode <> 0 OR @distributor IS NULL
    BEGIN
        RAISERROR (20036, 16, -1)
        RETURN (1)
    END

    /*
    ** For a local distributor, query the registry directly
    */
            
    if LOWER(@distributor) = LOWER(@@servername) and db_name() = @distribution_db
    begin

       /*We use the temp table because we want to return article_resolver value for 
            dotnet_assembly_name column for the non-dotnet resolvers, to be consistant
            with Yukon. In the underlying table, we just store NULL, since we will return NULL
            for this column in sp_lookupcustomresolver
       */
       create table #business_logic_handlers ( 
            article_resolver        nvarchar(255)   not null, 
            resolver_clsid          nvarchar(50)    not null, 
            is_dotnet_assembly      bit default 0, 
            dotnet_assembly_name    nvarchar(255)   null, 
            dotnet_class_name       nvarchar(255)   null
        )

        insert into #business_logic_handlers
        select * from dbo.MSmerge_articleresolver
        
        if @@ERROR<>0 return (1)        

        --now update the dotnet_assembly_name for non-dotnet resolvers
        update #business_logic_handlers
        set  dotnet_assembly_name = article_resolver
        where is_dotnet_assembly = 0          

        select * from #business_logic_handlers

        drop table #business_logic_handlers
    end
    /* 
    ** Since a downlevel publisher can connect to a remote distributor with a higher
    ** version, it is better to return the resolver list using the RPC as opposed
    ** to reading regkeys directly since they might change from version to version.
    */
    else
    begin
        select @distproc = quotename(RTRIM(@distributor)) + '.' + quotename(RTRIM(@distribution_db)) + '.sys.sp_enumcustomresolvers'
        exec @distproc 
        if @@ERROR<> 0 
            return (1)
    end

    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_enumcustomresolvers] TO [public] AS [dbo]
GO
