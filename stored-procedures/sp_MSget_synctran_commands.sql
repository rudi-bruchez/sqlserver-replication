SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_synctran_commands]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_synctran_commands] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_synctran_commands]
	@publication [sysname],
	@article [sysname],
	@command_only [bit],
	@publisher [sysname],
	@publisher_db [sysname],
	@alter [bit],
	@trig_only [bit],
	@usesqlclr [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE	@tabid          int,
			@retcode        int,
			@distributor    sysname,
			@pubid          int,
			@art_name       sysname,
			@all_article    bit,
			@is_synctran	bit,
			@is_queued      bit,
			@publisher_type sysname,
			@has_ts         bit,
			@has_ident      bit

    /* 
    ** Security Check.
    ** We use login_name stored in syssubscriptions to manage security 
    ** Do a relaxed security check here.
    */
    if (@trig_only = 0)
    begin
        exec @retcode = sys.sp_MSreplcheck_publish
        if @@ERROR <> 0 or @retcode <> 0
            return(1)
    end
    else
    begin
        exec @retcode = sp_MSreplcheck_pull
                        @publication = @publication,
                        @raise_fatal_error = 0
        if @@ERROR <> 0 or @retcode <> 0
            return(1)
    end

    /*
    ** Parameter Check:  @publication
    ** Check to make sure that the publication exists, that it's not NULL,
    ** and that it conforms to the rules for identifiers.
    */
    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_MSget_synctran_commands')
            RETURN (1)
        END

	-- Get publisher type
    if @trig_only = 0
    begin
    	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
    													@publisher_type	= @publisher_type OUTPUT,
													@skipSecurityCheck	= 1
    
    	IF @retcode <> 0
    	BEGIN
    		RETURN (1)
    	END
    end
    else
    begin
        select @publisher_type = N'MSSQLSERVER'
    end

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT

    IF @publisher IS NULL
    BEGIN
        set @publisher = publishingservername()
    END
    
    -- validate @publisher_db
    IF @publisher_db IS NULL
    BEGIN
        set @publisher_db = db_name()
    END
    
    --
    -- Verify publication exists
    --
	SELECT @pubid = sys.fn_MSrepl_getpubid(@publication, @publisher, @publisher_type)

	IF (@pubid IS NULL)
	BEGIN
		RAISERROR (20026, 11, -1, @publication)
		RETURN (1)
	END

    IF @usesqlclr = 1
    BEGIN
        EXEC @retcode = sys.sp_MSscriptsynctrancommands_sqlclr
            @publication = @publication
            ,@article = @article
            ,@publisher = @publisher
            ,@publisher_type = @publisher_type
            ,@command_only = @command_only
            ,@trig_only = @trig_only
		if (@@ERROR != 0 OR @retcode != 0)
	    begin
	        RETURN (1)
	    end
    END
    ELSE
    BEGIN

        create table #art_commands
        (
    	    artid		int NOT NULL,
    	    commands	nvarchar(max) collate database_default null,
    	    id			int identity NOT NULL
        )

        /*
        ** Initializations.
        */
        select @has_ts = 0, @has_ident = 0


        -- get publication metadata
        SELECT	@is_synctran		= allow_sync_tran,
                @is_queued			= allow_queued_tran
        FROM	syspublications 
        WHERE	pubid = @pubid

        -- If the publication does not allow sync tran or queued tran return nothing
        IF (@is_synctran = 0 AND @is_queued = 0)
            RETURN(0)
        --
        -- get the distributor details for this publisher
        --
        if @trig_only = 0
        begin
            exec @retcode = sys.sp_MSrepl_getdistributorinfo @distributor = @distributor OUTPUT
            if (@@ERROR != 0 OR @retcode != 0 or @distributor IS NULL)
            begin
                raiserror(14071, 16, -1)
                RETURN (1)
            end
        end
        else
        begin
            select @distributor = NULL
        end
        --
        -- validate @article
        --
        if lower(@article) = 'all'
            select @all_article = 1
        else
            select @all_article = 0
        --
        -- Process for each article in this metadata
        --
        DECLARE #hCsynctran_arts CURSOR LOCAL FAST_FORWARD FOR
	    SELECT	art.objid,
		    	art.name
	    FROM	sysarticles art,
	    		syspublications pub
	    WHERE	pub.pubid = @pubid
	      AND	pub.pubid = art.pubid
	      AND	(art.type & 0x1) = 1
	      AND	(art.name = @article OR @all_article = 1)
        FOR READ ONLY

        OPEN #hCsynctran_arts

        FETCH	#hCsynctran_arts
        INTO	@tabid,
    	    	@art_name
    
        WHILE (@@fetch_status <> -1)
        BEGIN
            -- Determine if table has timestamp property
            if ObjectProperty(@tabid, 'TableHasTimestamp') = 1 
        	    set @has_ts = 1
            if ObjectProperty(@tabid, 'TableHasIdentity') = 1 
        	    set @has_ident = 1

		    exec @retcode = sys.sp_MSarticle_synctran_commands
			    @publication = @publication
			    ,@article = @art_name
			    ,@command_only = 0  
			    ,@publisher = @publisher
			    ,@publisher_db = @publisher_db
			    ,@distributor = @distributor
			    ,@has_ts = @has_ts
			    ,@has_ident = @has_ident
                ,@trig_only = @trig_only
                ,@usesqlclr = @usesqlclr
			    -- omit @alter to get the default value, (0 for creation)
		    if (@@ERROR != 0 OR @retcode != 0)
	        begin
	            RETURN (1)
	        end
		    --
		    -- fetch metadata for next article
		    --
		    FETCH #hCsynctran_arts INTO @tabid, @art_name
        end
        CLOSE #hCsynctran_arts
        DEALLOCATE #hCsynctran_arts
        --
        -- Done with article related processing
        --
        if @command_only = 0 
            select * from #art_commands order by id
        else
            select commands from #art_commands order by id
        --
        -- all done
        --
    END
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSget_synctran_commands] TO [public] AS [dbo]
GO
