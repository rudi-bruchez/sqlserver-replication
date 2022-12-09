SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergealternatepublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergealternatepublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergealternatepublisher]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
	declare @subid				uniqueidentifier
	declare @pubid				uniqueidentifier
	declare @distributor		sysname
	declare @retcode			int

	declare @MShelpmergealternatepublisher TABLE
	(
		subid					uniqueidentifier	not null,
		alternate_publisher		sysname				collate database_default not null,	 
		alternate_publisher_db	sysname				collate database_default not null,	 
		alternate_publication	sysname				collate database_default not null,	 
		alternate_distributor	sysname				collate database_default null,	 
		friendly_name			nvarchar(255)		collate database_default null,	 
		enabled					bit					not null
	)
	
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    set @publisher= LOWER(@publisher collate SQL_Latin1_General_CP1_CS_AS)
	
	/*
	** Select the subscription's pubid and subid
	*/
	select @pubid = pubid from dbo.sysmergepublications	 
				where name = @publication and
					LOWER(publisher collate SQL_Latin1_General_CP1_CS_AS) = @publisher and
					publisher_db = @publisher_db
	if @pubid is NULL
	begin
	    -- since we are adding a sysmergepublications entry for the alternate publisher
	    -- see sp_MScreateglobalreplica - the entry should be there
		raiserror (21423, 11, -1, @publication)
		return (1)
	end

	if  1 <> {fn ISPALUSER(@pubid)} 
	begin
		raiserror(21423, 11, -1, @publication)
		return (1)
	end
		
    insert into @MShelpmergealternatepublisher 
        (subid, alternate_publisher, alternate_publisher_db, 
         alternate_publication, alternate_distributor, friendly_name, enabled)
    select distinct pub.pubid, pub.publisher, pub.publisher_db, 
          pub.name, pub.distributor, alt.description, 1
    from dbo.sysmergepublications pub, dbo.MSmerge_altsyncpartners alt
    where pub.pubid = alt.alternate_subid and alt.subid = @pubid

    insert into @MShelpmergealternatepublisher 
        (subid, alternate_publisher, alternate_publisher_db, 
         alternate_publication, alternate_distributor, friendly_name, enabled)
    select pubid, publisher, publisher_db, 
          name, distributor, description, 1
    from dbo.sysmergepublications where pubid = @pubid

    insert into @MShelpmergealternatepublisher 
        (subid, alternate_publisher, alternate_publisher_db, 
         alternate_publication, alternate_distributor, friendly_name, enabled)
    select distinct pub.pubid, pub.publisher, pub.publisher_db, 
          pub.name, pub.distributor, sub.description, 0
    from dbo.sysmergepublications pub, dbo.sysmergesubscriptions sub
    where pub.pubid not in (select subid from dbo.MSmerge_altsyncpartners) and
          pub.pubid not in (select alternate_subid from dbo.MSmerge_altsyncpartners) and
	      pub.pubid not in (select subid from @MShelpmergealternatepublisher) and
	      sub.pubid = pub.pubid and sub.pubid = sub.subid
	      
	select distinct alternate_publisher,
		alternate_publisher_db,
		alternate_publication,
		alternate_distributor,
		friendly_name,
		enabled 
		from @MShelpmergealternatepublisher 
	order by alternate_publisher, alternate_publisher_db, alternate_publication, alternate_distributor
	
	return (0)

GO
GRANT EXECUTE ON [sys].[sp_helpmergealternatepublisher] TO [public] AS [dbo]
GO
