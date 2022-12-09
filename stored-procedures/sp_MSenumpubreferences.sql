SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumpubreferences]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumpubreferences] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumpubreferences]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid uniqueidentifier
    declare @retcode int
    
    /* 
    ** Security Check.
    */
    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, NULL, NULL, @pubid output
    if @retcode<>0 or @@error<>0
        return 1
        
    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    select distinct ReferencingObject = object_name(referenced_object_id), ArticleObject = object_name(parent_object_id) 
        from sys.foreign_keys
        where parent_object_id in (select objid from dbo.sysmergearticles where pubid = @pubid) and
              referenced_object_id not in (select objid from dbo.sysmergearticles where pubid = @pubid)

    select distinct ReferencedObject = object_name(parent_object_id), ArticleObject = object_name(referenced_object_id) 
        from sys.foreign_keys
        where referenced_object_id in (select objid from dbo.sysmergearticles where pubid = @pubid) and
              parent_object_id not in (select objid from dbo.sysmergearticles where pubid = @pubid)

    -- We need to check if the publication role is already added.
    -- this has to be done here before the snapshot agent calls sp_Mspublicationview
    declare @role sysname
    exec @retcode = sys.sp_MSrepl_FixPALRole @pubid, @role output
    if (@role is NULL or @retcode <> 0 or @@error <> 0)
    begin
        -- add appropriate error message here
        return 1
    end

    -- we also need to fix the pal role for other publications which share an article
    -- with the current publication and the role for those publications are not
    -- present yet
    declare @pubidother uniqueidentifier
    declare pubs_cursor cursor LOCAL FAST_FORWARD
    for (select a.pubid from dbo.sysmergearticles a, dbo.sysmergepublications p
            where a.pubid <> @pubid and a.pubid = p.pubid 
                and LOWER(p.publisher)  collate database_default = LOWER(publishingservername()) collate database_default 
                and p.publisher_db = DB_NAME() and artid in 
                 (select artid from dbo.sysmergearticles where pubid = @pubid)) 
    open pubs_cursor
    fetch pubs_cursor into @pubidother
    while (@@fetch_status <> -1)
    begin
        exec @retcode = sys.sp_MSrepl_FixPALRole @pubidother, @role output
        if (@role is NULL or @retcode <> 0 or @@error <> 0)
        begin
            return 1
        end
        fetch pubs_cursor into @pubidother
    end
    close pubs_cursor
    deallocate pubs_cursor

    --exec sys.sp_MScheck_article_order @pubid
    
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumpubreferences] TO [public] AS [dbo]
GO
