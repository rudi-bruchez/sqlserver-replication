SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_restoremergeidentityrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_restoremergeidentityrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_restoremergeidentityrange]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid uniqueidentifier
    declare @artid uniqueidentifier
    declare @publisher_db sysname
    declare @publisher sysname
    declare @max_used numeric(38, 0)
    declare @identity_support int
    declare @retcode int
    declare @objid int
    declare @qualified_table_name nvarchar(300)
    declare @ident_increment numeric(38,0)
    declare @current_max_used numeric(38,0)
    declare @subid uniqueidentifier

    -- Security Check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    select @publisher_db = db_name()
    select @publisher = publishingservername()

    if LOWER(@publication) = 'all'
    BEGIN
        declare hC CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT name FROM dbo.sysmergepublications 
            WHERE UPPER(publisher) collate database_default = UPPER(@publisher) collate database_default 
                and publisher_db=@publisher_db
                and pubid in (select pubid from dbo.sysmergearticles where identity_support = 1)
            FOR READ ONLY
        OPEN hC
        FETCH hC INTO @publication
        WHILE (@@fetch_status <> -1)
            BEGIN
                EXECUTE @retcode = sys.sp_restoremergeidentityrange @publication, @article
                if @@error<>0 or @retcode<>0
                begin
                    CLOSE hC
                    DEALLOCATE hC
                    return 1
                end
                FETCH hC INTO @publication
            END
        CLOSE hC
        DEALLOCATE hC
        RETURN (0)
    END

    select @pubid = pubid
    from dbo.sysmergepublications 
    where name = @publication and UPPER(publisher) collate database_default = UPPER(@publisher) collate database_default and publisher_db=@publisher_db
    if @pubid is NULL
    begin
        raiserror (20026, 16, -1, @publication)
        return (1)
    end

    if LOWER(@article) = 'all'
    BEGIN
        declare hC CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT name FROM dbo.sysmergearticles 
                WHERE pubid=@pubid and identity_support=1 and (sys.fn_MSmerge_isrepublisher(artid)=0)
            FOR READ ONLY
        OPEN hC
        FETCH hC INTO @article
        WHILE (@@fetch_status <> -1)
            BEGIN
                EXECUTE @retcode = sys.sp_restoremergeidentityrange @publication, @article
                if @@error<>0 or @retcode<>0
                begin
                    CLOSE hC
                    DEALLOCATE hC
                    return 1
                end
                FETCH hC INTO @article
            END
        CLOSE hC
        DEALLOCATE hC
        RETURN (0)
    END

    select @artid=artid, @identity_support=identity_support, @objid=objid from dbo.sysmergearticles where pubid=@pubid and name=@article
    if @artid IS NULL or @objid is NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        goto ERROR
    END

    if @identity_support=0
    begin
        raiserror(20667, 16, -1, @article)
        goto ERROR
    end

    select @qualified_table_name = NULL
    exec sys.sp_MSget_qualified_name @objid, @qualified_table_name output
    if @qualified_table_name is NULL
    begin
        RAISERROR(20669 , 16, -1, @article)
        return (1)
    end

    select @ident_increment = IDENT_INCR(@qualified_table_name)
    
    select @max_used = NULL
    exec @retcode = sys.sp_MSget_max_used_identity_from_distributor @publication, @article, @max_used output
    if @@error<>0 or @retcode<>0 or @max_used is NULL
    begin
        raiserror(20729, 16, -1, @article, @publication)
        goto ERROR
    end

    select @subid = NULL, @current_max_used = NULL
    select @subid = subid, @current_max_used = max_used from dbo.MSmerge_identity_range 
        where artid = @artid and is_pub_range=1 and (sys.fn_MSmerge_islocalsubid(subid)=1)
    if @subid is NULL or @current_max_used is NULL
    begin
        raiserror(20663, 16, -1)
        goto ERROR
    end

    if (@ident_increment > 0 and @max_used > @current_max_used) or
       (@ident_increment < 0 and @max_used < @current_max_used)
    begin
        update dbo.MSmerge_identity_range set max_used = @max_used 
            where artid = @artid and is_pub_range=1 and subid=@subid
        if @@error<>0
            goto ERROR
    end
    
    return 0
    
ERROR:
    raiserror(20728, 16, -1, @article, @publication)
    return 1
GO
GRANT EXECUTE ON [sys].[sp_restoremergeidentityrange] TO [public] AS [dbo]
GO
