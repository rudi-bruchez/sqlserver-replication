SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_article]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_article] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_article]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    --
    -- security check
    -- only db_owner can execute this
    --
    if (is_member ('db_owner') != 1) 
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    
    select article, article_id, source_object, description, source_owner from MSarticles a where 
        a.publisher_id = (select srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)) and 
        a.publisher_db = @publisher_db and
        a.publication_id = (select publication_id from dbo.MSpublications where 
            publisher_id = a.publisher_id and
            publisher_db = a.publisher_db and
            publication = @publication) and
        a.article like @article
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_article] TO [public] AS [dbo]
GO
