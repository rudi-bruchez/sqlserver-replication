SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_scriptsubconflicttable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_scriptsubconflicttable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_scriptsubconflicttable]
	@publication [sysname],
	@article [sysname],
	@alter [bit],
	@usesqlclr [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int

    --
    -- Security Check.
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if (@@error != 0 or @retcode != 0)
        return (1)

    --
    -- Parameter Check: @publication.
    -- The @publication cannot be NULL and must conform to the rules
    -- for identifiers.
    --
    if (@publication IS NULL)
    begin
        raiserror (14043, 16, 2, '@publication', 'sp_scriptsubconflicttable')
        return (1)
    end
    exec @retcode = sys.sp_validname @publication
    if (@retcode != 0)
        return (1)

    --
    -- Parameter Check: @article.
    -- The @article cannot be NULL and must conform to the rules
    -- for identifiers.
    --  
    exec @retcode = sys.sp_MSreplcheck_name @article, '@article', 'sp_scriptsubconflicttable'
    if (@@error != 0 or @retcode != 0)
        return (1)

    if LOWER(@article) = 'all'
    begin
        raiserror (14032, 16, 2, '@article')
        return (1)
    end

    --
    -- now call the SP to generate the script
    --
    exec @retcode = sys.sp_MSmakeconflicttable @article = @article, @publication = @publication, @creation_mode = 1, @is_debug = 0, @alter = @alter, @usesqlclr = @usesqlclr
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_scriptsubconflicttable] TO [public] AS [dbo]
GO
