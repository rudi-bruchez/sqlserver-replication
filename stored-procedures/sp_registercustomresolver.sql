SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_registercustomresolver]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_registercustomresolver] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_registercustomresolver]
	@article_resolver [nvarchar](255),
	@resolver_clsid [nvarchar](50),
	@is_dotnet_assembly [nvarchar](10),
	@dotnet_assembly_name [nvarchar](255),
	@dotnet_class_name [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @retcode       int

    exec @retcode = sys.sp_MSreplcheck_publish
    if (@retcode <> 0 or @@error <> 0)
        return 1

    if @article_resolver IS NULL or @article_resolver = ''
    begin
        RAISERROR (21717, 16, -1)
        return 1
    end

    if LOWER(@is_dotnet_assembly collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14137, 16, -1)
           return 1
    END

    if LOWER(@is_dotnet_assembly collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    begin
        if @resolver_clsid IS NOT NULL 
        begin
            RAISERROR (21807, 16, -1)
            return 1
        end
        if @dotnet_assembly_name IS NULL or @dotnet_assembly_name = ''
        begin
            RAISERROR (21856, 16, -1, @article_resolver)
            return 1
        end
        if @dotnet_class_name IS NULL or @dotnet_class_name = ''
        begin
            RAISERROR (21808, 16, -1, @article_resolver)
            return 1
        end
        set @resolver_clsid = '00000000-0000-0000-0000-000000000000'
    end 
    else
    begin 
        if @resolver_clsid IS NULL or @resolver_clsid = ''
        begin
            RAISERROR (21718, 16, -1)
            return 1
        end
    end

    --this proc can only execute in the distribution database context
    if object_id (N'MSmerge_articleresolver') is null
    begin
        raiserror(25026, 16, -1)
        return 1
    end
    
   
    --Insert a new row into MSmerge_articleresolver if the resolver does not exist, otherwise, update it.            
    if LOWER(@is_dotnet_assembly collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    begin
         -- in the case when the resolver is a .NET resolver
         if not exists( select * from dbo.MSmerge_articleresolver where article_resolver = @article_resolver)
            insert into dbo.MSmerge_articleresolver( article_resolver, resolver_clsid, is_dotnet_assembly, dotnet_assembly_name, dotnet_class_name)
            values( @article_resolver, @resolver_clsid, 1, @dotnet_assembly_name, @dotnet_class_name)
        else
            update dbo.MSmerge_articleresolver
            set resolver_clsid = @resolver_clsid,
                 is_dotnet_assembly = 1,
                 dotnet_assembly_name = @dotnet_assembly_name,
                 dotnet_class_name = @dotnet_class_name
            where article_resolver = @article_resolver 

    end 
    else
    begin 
     -- in the case when the resolver is not a .NET resolver
         if not exists( select * from  dbo.MSmerge_articleresolver where article_resolver = @article_resolver)
            insert into dbo.MSmerge_articleresolver( article_resolver, resolver_clsid, is_dotnet_assembly, dotnet_assembly_name, dotnet_class_name)
            values( @article_resolver, @resolver_clsid, 0, NULL, NULL)
        else
            update dbo.MSmerge_articleresolver
            set resolver_clsid = @resolver_clsid,
                 is_dotnet_assembly = 0,
                 dotnet_assembly_name = NULL,
                 dotnet_class_name = NULL
            where article_resolver = @article_resolver
    end

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_registercustomresolver] TO [public] AS [dbo]
GO
