SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergealternatepublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergealternatepublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergealternatepublisher]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@alternate_publisher [sysname],
	@alternate_publisher_db [sysname],
	@alternate_publication [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
	declare @retcode				int
	declare @subid					uniqueidentifier
	declare @alternate_subid		uniqueidentifier
	declare @pubid                  uniqueidentifier
	
	/*
	** Security Check
	*/
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
		return (1)

	/* Check is there is an invalid attempt to drop the default publisher/publisher_db/publication */
	if (LOWER(@publisher) = LOWER(@alternate_publisher)) AND
		(@publisher_db = @alternate_publisher_db) AND
		(@publication = @alternate_publication)
		begin
			RAISERROR(21252, 11, -1,  @alternate_publisher, @alternate_publisher_db, @alternate_publication)
			return (1)
		end

	/*
	** Select the main publication's pubid and subid
	*/
	select @pubid = pubid from dbo.sysmergepublications	 
				where name = @publication and
					LOWER(publisher collate database_default) = LOWER(@publisher collate database_default) and
					publisher_db = @publisher_db
	if @pubid is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end
	
	-- this subid should really be equal to @pubid
	select @subid = subid from dbo.sysmergesubscriptions  
		where LOWER(subscriber_server) collate database_default = LOWER(@publisher) collate database_default and 
		db_name = @publisher_db and 
		pubid = @pubid and
		status <> 7 -- REPLICA_STATUS_BeforeRestore

    -- check if we know about the publication 
    -- we know of the publication if there is an entry in sysmergepublications corresponding to it
    -- the values of @alternate_subid should be same as 'alternate_pubid' in sysmergepublications
	select @alternate_subid = s.subid
	    from dbo.sysmergesubscriptions s, dbo.sysmergepublications p
		where p.name = @alternate_publication and
			  LOWER(p.publisher) collate database_default = LOWER(@alternate_publisher) collate database_default and 
			  p.publisher_db = @alternate_publisher_db and
			  p.pubid = s.pubid and
			  s.subid = s.pubid and
			  s.status <> 7 -- REPLICA_STATUS_BeforeRestore
	IF @subid is NULL or @alternate_subid IS NULL
	BEGIN
		RAISERROR(21216, 11, -1,  @alternate_publisher, @alternate_publisher_db, @alternate_publication)
		RETURN (1)
	END

	if exists (select * from MSmerge_altsyncpartners where subid = @subid and alternate_subid = @alternate_subid)
	begin
		delete from MSmerge_altsyncpartners where @subid = subid and alternate_subid = @alternate_subid
		if @@ERROR <> 0 or @@rowcount <> 1
		BEGIN
			GOTO FAILURE
		END
	end				
	return (0)

FAILURE:
	RAISERROR(21251, 11, -1,  @alternate_publisher, @alternate_publisher_db, @alternate_publication)
	RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergealternatepublisher] TO [public] AS [dbo]
GO
