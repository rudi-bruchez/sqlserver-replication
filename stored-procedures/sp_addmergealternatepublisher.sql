SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergealternatepublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergealternatepublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergealternatepublisher]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@alternate_publisher [sysname],
	@alternate_publisher_db [sysname],
	@alternate_publication [sysname],
	@alternate_distributor [sysname],
	@friendly_name [nvarchar](255),
	@reserved [nvarchar](20)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/
	declare @retcode				int
	declare @pubid					uniqueidentifier
	declare @subid					uniqueidentifier
	declare @alternate_subid		uniqueidentifier
	declare @description			nvarchar(255)
	declare @allow_synctoalternate	bit
	declare @at_publisher			bit
	declare @subscriber_type		smallint

	set @at_publisher = 1
	/*
	** Security Check
	*/
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
		return (1)
	
	/*
	** Select the subscription's pubid and subid
	*/
	select @pubid= pubid, @allow_synctoalternate= allow_synctoalternate
		from dbo.sysmergepublications	 
		where name = @publication and publisher_db = @publisher_db and LOWER(publisher) = LOWER(@publisher)

	if @pubid is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end

	/* If this is an external call, make the AtPublisher and allows syncto alternate  check */
	EXEC @retcode = sys.sp_MScheckatpublisher @pubid
	IF @@ERROR <> 0 or @retcode <>	0
		set @at_publisher = 0
		
	IF LOWER(@reserved collate SQL_Latin1_General_CP1_CS_AS) <> 'internal'
	begin
		IF @at_publisher = 0
		BEGIN
			RAISERROR (21215, 16, -1)
			RETURN (1)
		END
		if @allow_synctoalternate = 0
		begin
			raiserror (21502, 11, -1, @publication)
			return (1)
		end
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
	select @alternate_subid = s.subid, @subscriber_type = s.subscriber_type 
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
	
	IF @subscriber_type	 <> 1
	BEGIN
		RAISERROR(21216, 11, -1,  @alternate_publisher, @alternate_publisher_db, @alternate_publication)
		RETURN (1)
	END

	IF @friendly_name IS NULL
	begin
		select @description = description from dbo.sysmergesubscriptions where subid = @alternate_subid
		if @description IS NULL
		begin
			select @description = formatmessage(21217, @alternate_publication, @alternate_publisher)
		end
			
	end				
	else
		select @description = @friendly_name

	if not exists (select * from dbo.MSmerge_altsyncpartners where subid = @subid and alternate_subid = @alternate_subid)
	begin
		insert into dbo.MSmerge_altsyncpartners(subid, alternate_subid, description)
			values(@subid, @alternate_subid, @description)
		if @@ERROR <> 0 GOTO FAILURE

        -- Update sysmergepublications entry for the alternate publisher, setting the allow_synctoalternate = 1 
		update dbo.sysmergepublications set allow_synctoalternate = 1 where pubid = @alternate_subid
		if @@ERROR <> 0 GOTO FAILURE

        -- do not update alternate distributor. We already have info about it in the sysmergepublications table
		--update dbo.sysmergesubscriptions set distributor = @alternate_distributor where subid = @alternate_subid
		--if @@ERROR <> 0 or @@ROWCOUNT <> 1 GOTO FAILURE
	end				

	if not exists (select * from dbo.MSmerge_altsyncpartners where subid = @alternate_subid and alternate_subid = @subid)
	begin
		insert into dbo.MSmerge_altsyncpartners(subid, alternate_subid, description)
			values(@alternate_subid, @subid, @description)
		if @@ERROR <> 0 GOTO FAILURE
	end				
	return (0)

FAILURE:

	RAISERROR(21243, 11, -1,  @alternate_publisher, @alternate_publisher_db, @alternate_publication)
	RETURN (1)
	
GO
GRANT EXECUTE ON [sys].[sp_addmergealternatepublisher] TO [public] AS [dbo]
GO
