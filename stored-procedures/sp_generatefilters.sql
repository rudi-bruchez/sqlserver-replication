SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_generatefilters]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_generatefilters] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_generatefilters]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
/* Declare	a few variables */
	declare @pubid	uniqueidentifier
	declare @art_name sysname
	declare @object_id	int
	declare @join_objid int
	declare @retcode int
	declare @join_unique int
	declare @distance int
	
	/*
	** Security Check
	*/
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
		return (1)

	/*
	** Parameter Check: @publication.
	** The @publication id cannot be NULL and must conform to the rules
	** for identifiers.
	*/	 
		
	if @publication is NULL
		begin
			raiserror (14043, 16, -1, '@publication', 'sp_generatefilters')
			return (1)
		end
	/*
	** Get the pubid and make sure the publication exists
	*/
	select @pubid = pubid from dbo.sysmergepublications 
		where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
	if @pubid is NULL
	begin
		raiserror (20026, 16, -1, @publication)
		return (1)
	end

	/* Set up some temp tables to help keep track of what to process */
	create table #filtered (object_id int NOT NULL, distance int NOT NULL)
	create table #unfiltered (object_id int NOT NULL, art_name sysname collate database_default not null)

	/* Do initial population of temp tables */
	insert into #filtered (object_id, distance) select objid, 0 from dbo.sysmergearticles where
		pubid = @pubid and len(subset_filterclause) > 0
	insert into #unfiltered (object_id, art_name) select objid, name from dbo.sysmergearticles
		where pubid = @pubid and objid not in (select object_id from #filtered)

	/* remove self-referencing tables from #unfiltered as we should not try to filter them */
	delete from #unfiltered where object_id in
			(select referenced_object_id from sys.foreign_keys where referenced_object_id = parent_object_id)
	select @distance = min(distance) from #filtered f, sys.foreign_keys r, #unfiltered u where
		(f.object_id = r.referenced_object_id and r.parent_object_id = u.object_id) or
		(u.object_id = r.referenced_object_id and r.parent_object_id = f.object_id)
		
	/* Look for something in sys.foreign_keys to add a join filter for */
	select @join_unique = 1, @object_id = parent_object_id, @join_objid = referenced_object_id, @art_name = art_name
		from sys.foreign_keys r, #unfiltered u where r.parent_object_id = u.object_id and
		r.referenced_object_id in (select object_id from #filtered where distance = @distance) 

	if @art_name is null
		select	@join_unique = 0, @object_id = referenced_object_id, @join_objid = parent_object_id, @art_name = art_name
			from sys.foreign_keys r, #unfiltered u where r.referenced_object_id = u.object_id and
			r.parent_object_id in (select object_id from #filtered where distance = @distance) 
	while @art_name is not null
		begin
		/* Make the join filter corresponding to this relationship */
		exec @retcode=sys.sp_MSmakejoinfilter @publication, @art_name, @object_id, @join_objid, @join_unique
		if @@ERROR<>0 or @retcode<>0 return (1)
		/* Move row from #unfiltered to #filtered */
		insert into #filtered (object_id, distance) values (@object_id, @distance + 1)
		delete from #unfiltered where object_id = @object_id
		
		/* See if any more that can be added */
		select @distance = min(distance) from #filtered f, sys.foreign_keys r, #unfiltered u where
			(f.object_id = r.referenced_object_id and r.parent_object_id = u.object_id) or
			(u.object_id = r.referenced_object_id and r.parent_object_id = f.object_id)
		set @art_name = NULL
		select @join_unique = 1, @object_id = parent_object_id, @join_objid = referenced_object_id, @art_name = art_name
			from sys.foreign_keys r, #unfiltered u where r.parent_object_id = u.object_id and
			r.referenced_object_id in (select object_id from #filtered where distance = @distance) 
		if @art_name is null
			select	@join_unique = 0, @object_id = referenced_object_id, @join_objid = parent_object_id, @art_name = art_name
				from sys.foreign_keys r, #unfiltered u where r.referenced_object_id = u.object_id and
				r.parent_object_id in (select object_id from #filtered where distance = @distance) 
		end
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_generatefilters] TO [public] AS [dbo]
GO
