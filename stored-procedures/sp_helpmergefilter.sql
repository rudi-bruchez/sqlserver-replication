SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergefilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergefilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergefilter]
	@publication [sysname],
	@article [sysname],
	@filtername [sysname],
	@filter_type_bm [binary](1)
WITH EXECUTE AS CALLER
AS
set nocount on

    /*
    ** Declarations.
    */
    declare @pubid                    uniqueidentifier                
    declare @artid                    uniqueidentifier
    declare @retcode                int

    -- Security check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

    /*
    **    Calling sp_help* is all right whether current database is enabled for pub/sub or not
    */
    IF object_id('sysmergesubscriptions') is NULL
        RETURN (0)
        
    /*
    ** Parameter Check: @publication.
    ** The @publication id cannot be NULL and must conform to the rules
    ** for identifiers.
    */
    if @publication is NULL
        begin
            raiserror (14003, 16, -1)
            return (1)
        end
    /*
    ** Get the pubid and check if the publication does exist
    */
    select @pubid = pubid from dbo.sysmergepublications 
        where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
        begin
            raiserror (20026, 16, -1, @publication)
            return (1)
        end

    /*
    ** Parameter Check: @article.
    ** If an @article is specified, make sure it exists
    */
    select @artid = artid from dbo.sysmergeextendedarticlesview where name = @article and pubid = @pubid  
    if @artid is NULL and (@article <> '%' or @filtername <> '%')
        begin
            raiserror (20027, 16, -1, @article)
            return (1)
        end

    /*
    ** Parameter Check: @filter_type_bm.
    ** If a @filter_type_bm is invalid, assign it to the default value
    */
    if (@filter_type_bm is null) or (@filter_type_bm not in (1, 2, 3))
        select @filter_type_bm = 1 

    /*
        Return the merge filters from dbo.sysmergesubsetfilters
           if @filter_type_bm = 1, return the filters that has filter_type = 1 or 3   (join filters)
           if @filter_type_bm = 2, return the filters that has filter_type = 2  or 3  (logical record filters or filters that are both logical record filter and join filter)
           if @filter_type_bm = 3, return the filters that has filter_type = 1 or 2 or 3          (filters that are either join filter or logical record filter, or both)

    */

    IF @filtername <> '%'
        select distinct join_filterid, filtername, 'join article name' = j_a.name, join_filterclause, f.join_unique_key,
                'base table owner' = b_u.name, 'base table name' = b_o.name, 'join table owner' = j_u.name, 'join table name' = j_o.name,
                'article name' = b_a.name, f.filter_type
            from dbo.sysmergesubsetfilters f, sys.objects j_o, sys.objects b_o, sys.schemas j_u,
                sys.schemas b_u, dbo.sysmergeextendedarticlesview j_a, dbo.sysmergeextendedarticlesview b_a
            where    f.pubid = @pubid AND b_a.pubid = @pubid
                AND f.filtername = @filtername and (f.filter_type & @filter_type_bm) <> 0
                AND f.artid = @artid 
                AND f.artid = b_a.artid AND b_o.object_id = b_a.objid
                AND b_u.schema_id = b_o.schema_id
                AND f.join_nickname = j_a.nickname AND j_o.object_id = j_a.objid and j_a.pubid = @pubid
                AND j_u.schema_id = j_o.schema_id
               ORDER BY j_o.name, b_o.name
    ELSE
    begin
        if @artid is not null
            select distinct join_filterid, filtername, 'join article name' = j_a.name, join_filterclause, f.join_unique_key,
                    'base table owner' = b_u.name, 'base table name' = b_o.name, 'join table owner' = j_u.name, 'join table name' = j_o.name,
                    'article name' = b_a.name, f.filter_type
                from dbo.sysmergesubsetfilters f, sys.objects j_o, sys.objects b_o, sys.schemas j_u,
                    sys.schemas b_u, dbo.sysmergeextendedarticlesview j_a, dbo.sysmergeextendedarticlesview b_a
                where    f.pubid = @pubid AND b_a.pubid = @pubid
                    AND f.artid = @artid  and (f.filter_type & @filter_type_bm) <> 0
                    AND f.artid = b_a.artid AND b_o.object_id = b_a.objid
                    AND b_u.schema_id = b_o.schema_id
                    AND f.join_nickname = j_a.nickname AND j_o.object_id = j_a.objid and j_a.pubid = @pubid
                    AND j_u.schema_id = j_o.schema_id
                   ORDER BY j_o.name, b_o.name
        else
            select distinct join_filterid, filtername, 'join article name' = j_a.name, join_filterclause, f.join_unique_key,
                    'base table owner' = b_u.name, 'base table name' = b_o.name, 'join table owner' = j_u.name, 'join table name' = j_o.name,
                    'article name' = b_a.name, f.filter_type
                from dbo.sysmergesubsetfilters f, sys.objects j_o, sys.objects b_o, sys.schemas j_u,
                    sys.schemas b_u, dbo.sysmergeextendedarticlesview j_a, dbo.sysmergeextendedarticlesview b_a
                where    f.pubid = @pubid AND b_a.pubid = @pubid
                    AND f.artid = b_a.artid AND b_o.object_id = b_a.objid
                    AND b_u.schema_id = b_o.schema_id and (f.filter_type & @filter_type_bm) <> 0
                    AND f.join_nickname = j_a.nickname AND j_o.object_id = j_a.objid and j_a.pubid = @pubid
                    AND j_u.schema_id = j_o.schema_id
                   ORDER BY j_o.name, b_o.name
    end
    return(0)
GO
GRANT EXECUTE ON [sys].[sp_helpmergefilter] TO [public] AS [dbo]
GO
