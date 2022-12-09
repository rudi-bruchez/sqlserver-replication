SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_enumsubscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_enumsubscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_enumsubscriptions]
	@publication [sysname],
	@publisher [sysname],
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on
	DECLARE @retcode int
				,@dbname sysname
				,@hasadminaccess bit
				,@login_name sysname
				,@category int
				,@fpublished bit
			
	--
	-- Security Check.
	-- Part of the query to gather the list of publications uses security context
	-- Optimization done for syadmin or dbowner
	--
	select @dbname = db_name()
			,@hasadminaccess = case when (is_member('db_owner') = 1 OR is_srvrolemember('sysadmin') = 1) then 1 else 0 end
			,@login_name = suser_sname(suser_sid())
		
	-- Verify database is published
	-- Have put the code from fn_MSrepl_ispublished inline for faster processing
	-- If fn_MSrepl_ispublished() is updated - this code block should be updated as well
	SELECT @category = category
	FROM master.sys.sysdatabases
	WHERE name = @dbname 

    IF (@category IS NOT NULL)
    BEGIN
        -- We have entry for this db_name in sysdatabases
        -- Is this database a distributor?
        IF (@category & 16 = 16)
        BEGIN
            -- DB is a distributor - is it used for HREPL publisher?
            IF OBJECT_ID(N'msdb.dbo.MSdistpublishers') IS NOT NULL
            BEGIN
                IF EXISTS
                (
                    SELECT name
                    FROM msdb.dbo.MSdistpublishers
                    WHERE distribution_db = @dbname 
                        AND publisher_type != N'MSSQLSERVER'
                )
                BEGIN
                    SELECT @fpublished = 1
                END
            END
        END
        ELSE
        BEGIN
            -- Check if this database is a transactional or merge publisher
            IF (@category & 1 = 1 OR @category & 4 = 4)
            BEGIN
                SELECT @fpublished = 1
            END
        END
    END -- @category not null
    --
    -- If the database is not published - return
    --
    IF (@fpublished = 0) 
        RETURN (0)
    --
    -- set publisher
    --
    if (@publisher IS NULL)
        select @publisher = publishingservername()
    --
    -- Create temp table if needed
    --
    if (@reserved = 0)
    begin
        create table #tmp_pubsubscriptions
        (
            publisher sysname not null,
            publisher_db sysname not null,
            publisher_type sysname not null,
            publication sysname not null,
            publication_type int not null,
            subscription_name nvarchar(258) not null,
            subscriber sysname not null,
            subscriber_db sysname not null,
            subscription_type int not null,
            priority float(8) not null default 0.0
        )
    end
    -- Get snapshot or transactional subscriptions
    if (object_id(N'dbo.syssubscriptions') is not null)
    BEGIN
        IF (@category & 16 != 16)
        BEGIN
            -- SQL publication db
            INSERT INTO #tmp_pubsubscriptions
            (
                publisher,
                publisher_db,
                publisher_type,
                publication,
                publication_type,
                subscription_name,
                subscriber,
                subscriber_db,
                subscription_type
            )
            SELECT DISTINCT
                @publisher,
                @dbname,
                N'MSSQLSERVER',
                pub.name,
                pub.repl_freq,
                sub.srvname collate database_default + N':' + sub.dest_db,
                sub.srvname,
                sub.dest_db,
                sub.subscription_type
            FROM dbo.syssubscriptions as sub
                join dbo.sysextendedarticlesview as art on sub.artid = art.artid
                join dbo.syspublications as pub on art.pubid = pub.pubid
            WHERE pub.name = @publication
              AND (@hasadminaccess = 1 OR sub.login_name = @login_name)
              and sub.srvname is not null and len(sub.srvname) > 0
              -- GROUP BY srv.name, sub.dest_db, pub.name, pub.repl_freq, sub.subscription_type
        END
        ELSE
        BEGIN
            -- Heterogeneous subscriptions
            INSERT INTO #tmp_pubsubscriptions
            (
                publisher,
                publisher_db,
                publisher_type,
                publication,
                publication_type,
                subscription_name,
                subscriber,
                subscriber_db,
                subscription_type
            )
            SELECT DISTINCT
                pubsrv.srvname,
                pubsrv.srvname,
                msd.publisher_type,
                pub.name,
                pub.repl_freq,
                subsrv.srvname collate database_default + N':' + sub.dest_db,
                subsrv.srvname,
                sub.dest_db,
                sub.subscription_type
            FROM dbo.syssubscriptions as sub
                join MSreplservers as subsrv on sub.srvid = subsrv.srvid
                join dbo.sysarticles as art on sub.artid = art.artid
                join dbo.syspublications as pub on art.pubid = pub.pubid
                join dbo.MSpublications as msp on pub.pubid = msp.publication_id
                join MSreplservers as pubsrv on pubsrv.srvid = msp.publisher_id
                join msdb.dbo.MSdistpublishers as msd on msd.name = pubsrv.srvname
            WHERE pub.name = @publication
              AND pubsrv.srvname = @publisher
              AND (@hasadminaccess = 1 OR sub.login_name = @login_name)
        END
    END

	-- Get merge subscriptions
	if (object_id(N'dbo.sysmergesubscriptions') is not null)
	BEGIN
		INSERT INTO #tmp_pubsubscriptions
		(
			publisher,
			publisher_db,
			publisher_type,
			publication,
			publication_type,
			subscription_name,
			subscriber,
			subscriber_db,
			subscription_type,
			priority
		)
		SELECT DISTINCT
			pub.publisher,
			pub.publisher_db,
			N'MSSQLSERVER',
			pub.name,
			2,
			sub.subscriber_server + N':' + sub.db_name,
			sub.subscriber_server,
			sub.db_name,
			sub.subscription_type,
			sub.priority
		FROM dbo.sysmergesubscriptions as sub
			join dbo.sysmergepublications as pub on pub.pubid = sub.pubid
			join dbo.MSmerge_replinfo as rep on rep.repid = sub.subid
		WHERE sub.status != 2
			AND sub.subscriber_type <> 3
			AND sub.subid  != sub.pubid
			AND pub.name = @publication
			AND (@hasadminaccess = 1 OR rep.login_name = @login_name)
	END

	-- Return result set if needed
	if (@reserved = 0)
	begin
		SELECT *
		FROM #tmp_pubsubscriptions
		ORDER BY publisher, subscriber, subscriber_db
	end
	-- all done
	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_enumsubscriptions] TO [public] AS [dbo]
GO
