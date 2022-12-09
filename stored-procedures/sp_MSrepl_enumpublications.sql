SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_enumpublications]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_enumpublications] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_enumpublications]
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @retcode int
				,@pubid int
				,@pubname sysname
				,@username sysname
				,@OPT_ENABLED_FOR_P2P int
				,@category int
				,@skippalcheck bit
				,@dbname sysname
				,@fpublished bit
				,@OPT_ENABLED_FOR_P2PCONFLICTDETECTION int

	--
	-- initialize
	--
	select @dbname = db_name()
			,@OPT_ENABLED_FOR_P2P = 0x1
			,@username = SUSER_SNAME()
			,@fpublished = 0
			,@OPT_ENABLED_FOR_P2PCONFLICTDETECTION = 0x08
	--
	-- Verify database is published
	-- Have put the code from fn_MSrepl_ispublished inline for faster processing
	-- If fn_MSrepl_ispublished() is updated - this code block should be updated as well
	--
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
	BEGIN
		RETURN (0)
	END
	--
	-- Security Check.
	-- Skip PAL check if DBO 
	-- For PAL check - Part of the query to gather the list of publications uses security context
	--
	select @skippalcheck = case when (is_member ('db_owner') = 1 OR is_srvrolemember('sysadmin') = 1) then 1 else 0 end
	if (@skippalcheck = 0)
	begin
		DECLARE @accessiblepubs TABLE
		(
			pubid   int
		)
	end
	--
	-- Create local temp table if needed
	--
	if (@reserved = 0)
	begin
		create TABLE #tmp_publications
		(
			publisher sysname not null, 
			dbname sysname not null, 
			publication sysname not null, 
			publisher_type sysname not null, 
			publication_type int not null,
			description nvarchar(255) null,
			allow_queued bit default 0 NOT NULL,
			enabled_for_p2p bit default 0 NOT NULL,
			enabled_for_p2pconflictdetection bit default 0 NOT NULL
		)
	end
	--
	-- Get snapshot or transactional publications
	--
	IF object_id(N'dbo.syspublications') IS NOT NULL
	BEGIN
		if (@skippalcheck = 0)
		begin
			-- Catalog accessible pub ids
			DECLARE #hC CURSOR LOCAL FAST_FORWARD FOR 
			SELECT pubid, name
			FROM dbo.syspublications

			OPEN #hC
			FETCH #hC INTO @pubid, @pubname
			WHILE (@@fetch_status <> -1)
			BEGIN
				EXEC @retcode = sys.sp_MSreplcheck_pull @publication = @pubname,
												@raise_fatal_error = 0,
												@given_login = @username
				IF (@retcode = 0 AND @@error = 0)
				BEGIN
					INSERT INTO @accessiblepubs values(@pubid)
				END

                FETCH #hC INTO @pubid, @pubname
            END
            CLOSE #hC
            DEALLOCATE #hC
        end -- if (@skippalcheck = 0)
        --
        -- Determine if distribution db is being cataloged
        --
        IF (@category & 16 != 16)
        BEGIN
            -- SQL Server publication db
            INSERT INTO #tmp_publications
            (
                publisher,
                dbname,
                publication,
                publisher_type,
                publication_type,
                description,
                allow_queued,
                enabled_for_p2p,
                enabled_for_p2pconflictdetection
            )
            SELECT publishingservername(),
                        @dbname,
                        name,
                        N'MSSQLSERVER',
                        repl_freq,
                        description,
                        allow_queued_tran,
                        (options & @OPT_ENABLED_FOR_P2P),
                        (options & @OPT_ENABLED_FOR_P2PCONFLICTDETECTION)
            FROM dbo.syspublications
            WHERE @skippalcheck = 1 
                OR (pubid IN (SELECT pubid FROM @accessiblepubs))
        END
        ELSE
        BEGIN
            -- Distribution db - Heterogeneous publications
            INSERT INTO #tmp_publications
            (
                publisher,
                dbname,
                publication,
                publisher_type,
                publication_type,
                description,
                allow_queued,
                enabled_for_p2p
            )
            SELECT ss.srvname,
                        @dbname, -- distribution db name for enumerator to work
                        sp.name,
                        msd.publisher_type,
                        sp.repl_freq,
                        sp.description,
                        sp.allow_queued_tran,
                        (sp.options & @OPT_ENABLED_FOR_P2P)
            FROM dbo.syspublications sp
                join dbo.MSpublications msp on sp.pubid = msp.publication_id
                join MSreplservers ss on msp.publisher_id = ss.srvid
                join msdb.dbo.MSdistpublishers msd on msd.name = ss.srvname
            WHERE @skippalcheck = 1 
                OR (pubid IN (SELECT pubid FROM @accessiblepubs))
        END
    END -- IF object_id(N'dbo.syspublications') IS NOT NULL
    --
    -- Get merge publications
    --
    IF object_id(N'dbo.sysmergepublications') IS NOT NULL
    BEGIN
        INSERT INTO #tmp_publications
        (
            publisher,
            dbname,
            publication,
            publisher_type,
            publication_type,
            description
        )
        SELECT publisher,
                    publisher_db,
                    name,
                    N'MSSQLSERVER',
                    2,
                    description
        FROM dbo.sysmergepublications
        WHERE (@skippalcheck = 1 OR {fn ISPALUSER(pubid)} = 1)
            and   publisher_db = @dbname 
            and   UPPER(publisher) = UPPER(publishingservername())
    END -- object_id(N'dbo.sysmergepublications') IS NOT NULL
    --
    -- Return result set if we created local table
    --
    if (@reserved = 0)
    begin
        SELECT *
        FROM #tmp_publications
        ORDER BY publisher, dbname, publication
    end
    --
    -- all done
    --
    RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_enumpublications] TO [public] AS [dbo]
GO
