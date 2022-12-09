SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergearticlecolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergearticlecolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergearticlecolumn]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @colid        int
    declare @colmax        int
    declare @colname    sysname
    declare @published    bit
    declare @columns    binary(128)
    declare @pubid        uniqueidentifier
    declare @retcode    int
    declare @objid        int
    declare @publisher    sysname
    declare @publisher_db    sysname

    select @publisher = publishingservername()
    select @publisher_db = db_name()

    /*
    ** Parameter Check: @publication.
    ** The @publication name must conform to the rules for identifiers.
    */
    IF @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_helpmergearticlecolumn')
        RETURN (1)
    END
    
    EXECUTE @retcode = sys.sp_validname @publication
    IF @retcode <> 0 or @@ERROR<>0
    RETURN (1)
    
    SELECT @pubid = pubid FROM dbo.sysmergepublications WHERE name = @publication 
                                                            and LOWER(publisher)=LOWER(@publisher)
                                                            and publisher_db = @publisher_db
    IF @pubid IS NULL
    BEGIN
        RAISERROR (21423, 11, -1, @publication)
        RETURN (1)
    END

    -- Security check. (Done after @pubid retrieval, because this param is needed here.)
    if  1 <> {fn ISPALUSER(@pubid)} and
        (1 <> is_member('replmonitor') or is_member('replmonitor') is null) 
    begin
        raiserror(21423, 11, -1, @publication)
        return 1
    end

    /*
    ** Parameter Check: @article.
    ** The @article name must conform to the rules for identifiers.
    */

    IF @article IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@article', 'sp_helpmergearticlecolumn')
            RETURN (1)
        END
    EXECUTE @retcode = sys.sp_validname @article
    IF @retcode <> 0 or @@ERROR<>0
        RETURN (1)

    /*
    ** Parameter Check:     @article, @publication.
    ** Check to make sure that the article exists in this publication.
    */

    IF NOT EXISTS (SELECT * FROM dbo.sysmergearticles WHERE pubid = @pubid AND name = @article)
        BEGIN
            RAISERROR (20027, 11, -1, @article)
            RETURN (1)
        END

    SELECT @columns = columns, @objid=objid FROM dbo.sysmergearticles
        WHERE name = @article AND pubid = @pubid

    create table #tmp (column_id int, column_name sysname collate database_default, published bit)
    select TOP 1 @colid = column_id from sys.columns where object_id = @objid order by column_id ASC
    select TOP 1 @colmax = column_id from sys.columns where object_id = @objid order by column_id DESC
    while (@colid <= @colmax)
    begin
    if exists (select * from sys.columns where object_id = @objid and column_id = @colid)
        begin
            select @colname = name from sys.columns where object_id=@objid and column_id=@colid
            exec @retcode = sys.sp_MStestbit @bm=@columns, @coltotest=@colid
            if @retcode<>0
                select @published=1
            else
                select @published=0
            insert into #tmp values(@colid, @colname, @published)
        end
        select @colid=@colid + 1
    end
    select * from #tmp
    drop table #tmp
GO
GRANT EXECUTE ON [sys].[sp_helpmergearticlecolumn] TO [public] AS [dbo]
GO
