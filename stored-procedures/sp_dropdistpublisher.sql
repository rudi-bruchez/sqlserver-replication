SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropdistpublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropdistpublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropdistpublisher]
	@publisher [sysname],
	@no_checks [bit],
	@ignore_distributor [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

    DECLARE @distributor sysname
    DECLARE @distaccount nvarchar(127)
    DECLARE @proc nvarchar (255)
    DECLARE @retcode int
    DECLARE @privilege sysname
    DECLARE @return_status int
    DECLARE @found int
    DECLARE @distribdb sysname
    DECLARE @command nvarchar(255)
    DECLARE @active_value int
    DECLARE @publish_bit int
    DECLARE @mergepub_bit int
    DECLARE @vendor sysname
    DECLARE @publisher_type sysname
    DECLARE @tempdistr sysname
    DECLARE @tempdistrdb sysname
    DECLARE @cmd nvarchar(255)
    DECLARE @publisher_db sysname
    DECLARE @hrepl bit
    DECLARE @sa_login sysname
	DECLARE @distagproc nvarchar(1000)
	DECLARE @distdb_in_secondary bit  -- is distribution db is in secondary state on this node
	DECLARE @loc_distributor sysname  -- server name of the distributor
	DECLARE @loc_distribdb sysname    -- distribution db for the supplied @publisher

	SELECT @found = 0
	SELECT @hrepl = 1

	SELECT @publish_bit = 1
	SELECT @mergepub_bit = 4

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	/*
	** Parameter Check:  @publisher.
	** Check to make sure that the publisher exists, that the name isn't
	** NULL, and that the name conforms to the rules for identifiers.
	*/

	IF @publisher IS NULL
	BEGIN
		RAISERROR (14043, 16, -1, '@publisher', 'sp_dropdistpublisher')
		RETURN (1)
	END

	EXECUTE @retcode = sys.sp_validname @publisher

	IF @retcode <> 0
	BEGIN
		RETURN (1)
	END

    -- Make publisher name case insensitive
    SELECT @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT

	-- Check if dist db is secondary in AG and if it is in readable state
    SELECT @loc_distributor = upper(data_source collate database_default) FROM sys.servers WHERE is_distributor = 1
 
    IF (@loc_distributor is not null and @loc_distributor = UPPER(@@servername))
	    BEGIN
			 -- invoked on distributor
			 -- Find the distribution DB name for publisher @publisher
			select @loc_distribdb = distribution_db from msdb.dbo.MSdistpublishers msd where msd.name = @publisher

			if (sys.fn_MSrepl_isdistdbsecondary(@loc_distribdb) = 1)
			BEGIN 
				if not exists (select * from sys.availability_replicas where replica_id = 
									(
									select hdr.replica_id from sys.dm_hadr_database_replica_states as hdr where hdr.database_id = db_id(@loc_distribdb collate database_default)
									)	
								and secondary_role_allow_connections = 2
								)
							BEGIN
								RAISERROR (25036, 16, -1)
								RETURN (1)
							END
			END 	
	    END
		    
        /*
    ** Get distribution server information for remote RPC
    ** agent verification.
    */
    EXEC @retcode =	sys.sp_MSrepl_getdistributorinfo	@publisher		= @publisher,
                                                        @distributor	= @distributor    OUTPUT,
                                                        @distribdb		= @distribdb      OUTPUT,
                                                        @publisher_type	= @publisher_type OUTPUT

	IF @@error <> 0 OR @retcode <> 0 OR @distributor IS NULL
	BEGIN
		RAISERROR (14071, 16, -1)
		RETURN (1)
	END
	
	/*
	** Only a local distributor can be modified.
	*/
	IF UPPER(@distributor) <> UPPER(@@SERVERNAME)
	BEGIN
		RAISERROR (14114, 16, -1, @@SERVERNAME)
		RETURN (1)
	END

    -- Verify publisher exists
    IF NOT EXISTS
    (
        SELECT	*
        FROM	msdb..MSdistpublishers
        WHERE	UPPER(name  collate database_default) = UPPER(@publisher) collate database_default
    )
    BEGIN
        RAISERROR (14080, 11, -1, @publisher)
        RETURN (1)
    END
	
	select @distdb_in_secondary = sys.fn_MSrepl_isdistdbsecondary(@distribdb)

    IF (UPPER(@publisher) = UPPER(@distributor) and (@distdb_in_secondary = 1))
    BEGIN
        RAISERROR(25035, 16, -1)
        RETURN (1)
    END

    IF @publisher_type = N'MSSQLSERVER' AND UPPER(@publisher) = UPPER(@@SERVERNAME)
    BEGIN
        /* 
        ** If @publisher is local, 
        ** 1. check to make sure there is no subscriber for publisher in distribution database
        ** 2. check to make sure there no databases enabled for replication
        */
        IF @ignore_distributor = 0
        BEGIN
            -- Check to see if there are subscribers defined.
            EXEC @retcode = sys.sp_MSrepl_helpsubscriberinfo	@publisher  = @publisher,
                                                                @subscriber = N'%',
                                                                @found		= @found OUTPUT

			IF @retcode <> 0 OR @@ERROR <> 0
			BEGIN
				RETURN (1)
			END

			IF @found = 1
			BEGIN
				RAISERROR(21047, 16, -1)
				RETURN(1)
			END
		END

        -- Check to see if any db's enabled for replication
        IF EXISTS
        (
            SELECT	*
            FROM	master.dbo.sysdatabases
            WHERE	(category & @publish_bit) <> 0
               OR	(category & @mergepub_bit) <> 0
        )
        BEGIN 
            RAISERROR (21033, 16, -1, @@SERVERNAME)
            RETURN (1)
        END
    END
    ELSE
    BEGIN
        IF @no_checks = 0
        BEGIN
            /* 
            ** If the publisher is remote, check the status of the distpublisher 
            ** The status will be inactive if the remote publisher dropped the
            ** distributor.
            */
            IF @publisher_type = N'MSSQLSERVER'
            BEGIN
                IF EXISTS
                (
                	SELECT	*
                	FROM	msdb.dbo.MSdistpublishers
                	WHERE	UPPER(name  collate database_default) = UPPER(@publisher) collate database_default
                	  AND	active = 1
                ) AND (@distdb_in_secondary = 0)
                BEGIN
                    RAISERROR (14098, 16, -1, @publisher, @@SERVERNAME)
                    RETURN (1)
                END
            END
        END
    END

	IF (@publisher_type != N'MSSQLSERVER') and (@distdb_in_secondary = 1)
	BEGIN
		RAISERROR(25034, 16, -1)
		RETURN (1)
	END

    IF @ignore_distributor = 0
    BEGIN
        IF NOT @publisher_type = N'MSSQLSERVER'
        BEGIN
            SELECT @command = QUOTENAME(@distribdb) + '.sys.sp_IHdroppublisher'
            exec @retcode = @command @publisher, @publisher_type, @no_checks
            
            IF ((@retcode != 0) OR (@@ERROR != 0)) AND (@no_checks = 0)
            BEGIN
                -- Note failure and return an error at the end
                SET @hrepl = 0
            END
        END

		If (@distdb_in_secondary = 0)
		BEGIN
			SELECT @command = QUOTENAME(@distribdb) + '.dbo.sp_MSdistpublisher_cleanup'
			EXEC @retcode = @command @publisher
			IF @retcode <> 0 or @@error <> 0
			BEGIN
				RETURN(1)
			END
		END
	END

	DECLARE @fExists int

	-- get the servername that was persisted in the sysservers table
	SELECT @publisher = sys.fn_getpersistedservernamecasevariation(@publisher) collate database_default
	SELECT @sa_login = SUSER_SNAME(0x01)
	
 
	EXEC @fExists = sys.sp_MSIfExistsRemoteLogin @publisher,
												'distributor_admin',
												@sa_login

	IF (@fExists = 1)
	BEGIN
		EXEC @retcode = sys.sp_dropremotelogin	@publisher,
												'distributor_admin',
												@sa_login

		IF @@ERROR <> 0 OR @retcode <> 0
		BEGIN
			RETURN (1)
		END
	END

	EXEC @fExists = sys.sp_MSIfExistsRemoteLogin	@publisher,
													'distributor_admin',
													'distributor_admin'
	
	IF (@fExists = 1)
	BEGIN
		EXECUTE @retcode = sys.sp_dropremotelogin	@publisher,
													   'distributor_admin',
													   'distributor_admin'
													   
		IF @@ERROR <> 0 OR @retcode <> 0
		BEGIN
			RETURN (1)
		END
	END

	-- store entry prior to delete so we can manually rollback
	-- in case of a failure durring the remaining steps. we can
	-- not use transactions since sp_dropserver can not be exec'd
	-- within a transaction... and we can not wait on the delete
	-- till after the dropserver since drop server will check for 
	-- this entry and fail if there is a distpub for this server
	SELECT *
		INTO #MSdistpublishers
		FROM msdb..MSdistpublishers
		WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
	
	-- Remove the publisher now that most of cleanup has completed
	-- only thing that remains is the dop of server...
	DELETE msdb..MSdistpublishers
		WHERE UPPER(name collate database_default) = UPPER(@publisher) collate database_default
	IF @@ERROR <> 0
	BEGIN
		RETURN (1)
	END
	
	IF (@publisher_type = N'MSSQLSERVER')
	BEGIN
		--
		-- SQL Server specific
		-- drop RPC server entry for remote publisher
		--
		IF (upper(@distributor) != upper(@publisher))
		BEGIN
			IF EXISTS
			(
				SELECT	*
				FROM	master.dbo.sysservers
				WHERE	upper(srvname collate database_default) = upper(@publisher)
			)
			BEGIN
				EXEC @retcode = sys.sp_dropserver @publisher, 'droplogins'

				IF (@@error != 0 or @retcode != 0)
				BEGIN
					GOTO FAILURE
				END

				if (@distdb_in_secondary = 0)
				BEGIN
					-- delete relevant entry from MSreplservers
					set @distagproc = 'delete from ' + QUOTENAME(@distribdb) + '..MSreplservers where  UPPER(srvname collate database_default) = UPPER(' + QUOTENAME(@publisher, '''') + '  collate database_default)'
					exec (@distagproc)
				END
			END
		END
	END
	ELSE
	BEGIN
		-- For heterogeneous publishers drop the remote server and it's logins
		exec @retcode = sys.sp_dropserver @publisher, 'droplogins'

		IF @@ERROR <> 0 OR @retcode <> 0
		BEGIN
			GOTO FAILURE
		END

		-- delete relevant entry from MSreplservers
		set @distagproc = 'delete from ' + QUOTENAME(@distribdb) + '..MSreplservers where  UPPER(srvname collate database_default) = UPPER(' + QUOTENAME(@publisher, '''') + '  collate database_default)'
		exec (@distagproc)

		-- Drop expired subscription cleanup job and alerts
		EXEC @retcode = sys.sp_MSrepl_drop_expired_sub_cleanup_job @publisher

		IF (@@ERROR != 0 OR @retcode != 0)
		BEGIN
			GOTO FAILURE
		END
	END
	
	-- Override status and return an error if HREPL failed.
	-- Post-hrepl steps will have completed and left the distributor
	-- in a consistent state.
	IF @hrepl = 0
	BEGIN
		-- Report failure to drop publisher info but don't finish cleanup
		RAISERROR(21749, 16, -1, @publisher)
		GOTO FAILURE
	END

	RETURN (0)
FAILURE:
	INSERT INTO msdb..MSdistpublishers
		SELECT *
			FROM #MSdistpublishers

	RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_dropdistpublisher] TO [public] AS [dbo]
GO
