SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergepullsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergepullsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergepullsubscription_agent]
	@name [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [sysname],
	@publisher_encrypted_password [bit],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_security_mode [int],
	@subscriber_login [sysname],
	@subscriber_password [sysname],
	@distributor [sysname],
	@distributor_security_mode [int],
	@distributor_login [sysname],
	@distributor_password [sysname],
	@encrypted_password [bit],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int],
	@optional_command_line [nvarchar](255),
	@merge_jobid [binary](16) OUTPUT,
	@enabled_for_syncmgr [nvarchar](5),
	@ftp_address [sysname],
	@ftp_port [int],
	@ftp_login [sysname],
	@ftp_password [sysname],
	@alt_snapshot_folder [nvarchar](255),
	@working_directory [nvarchar](255),
	@use_ftp [nvarchar](5),
	@reserved [nvarchar](100),
	@use_interactive_resolver [nvarchar](5),
	@offloadagent [nvarchar](5),
	@offloadserver [sysname],
	@job_name [sysname],
	@dynamic_snapshot_location [nvarchar](260),
	@use_web_sync [bit],
	@internet_url [nvarchar](260),
	@internet_login [sysname],
	@internet_password [nvarchar](524),
	@internet_security_mode [int],
	@internet_timeout [int],
	@hostname [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN

    SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @command                 	nvarchar(4000)
            ,@retcode                 	int
            ,@database                	sysname
            ,@repid                    	uniqueidentifier
            ,@pubid                    	uniqueidentifier
            ,@name_id                	nvarchar(50)
            ,@subscription_type_id    	int
            ,@category_name            	sysname
            ,@platform_nt            	binary
            ,@subscriber_enc_password    nvarchar(524)
            ,@publisher_enc_password     nvarchar(524)
            ,@distributor_enc_password   nvarchar(524)
            ,@internet_enc_password     	nvarchar(524)
            ,@use_ftp_bit            	bit
            ,@use_interactive_bit    	bit
            ,@merge_job_step_uid     	uniqueidentifier
            ,@edition_id int

    select @platform_nt = 0x1
            ,@use_ftp_bit = 0
            ,@merge_job_step_uid = NULL
            ,@edition_id = sys.fn_MSrepl_editionid ()
            
    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        return 1
    end

    -- For attach check
    if object_id(N'dbo.MSrepl_restore_stage') is not null
    begin
        raiserror(21211, 16, -1)
        return 1
    end

    -- Set null @optional_command_line to empty string to avoid string concat problem
    if @optional_command_line is null
        set @optional_command_line = ''
    else
        set @optional_command_line = N' ' + LTRIM( RTRIM(@optional_command_line) ) + N' '

    IF @distributor_password = N''
        select @distributor_password = NULL

    IF @publisher_password = N''
        select @publisher_password = NULL

    IF @internet_password = N''
        select @internet_password = NULL

    IF @ftp_password = N''
        select @ftp_password = NULL

    if @distributor is NULL
        select @distributor = @publisher
        
    -- Get distributor port number
    declare @distributor_with_port sysname
    exec sys.sp_MSget_server_portinfo 
        @name = @distributor, 
        @srvname = @distributor OUTPUT,
        @srvname_with_port = @distributor_with_port OUTPUT

    -- Get publisher port number
    declare @publisher_with_port sysname
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT,
        @srvname_with_port = @publisher_with_port OUTPUT

    /*
    ** Parameter Check: @subscriber and @subscriber_db
    */

    IF @subscriber IS NOT NULL 
    	OR @subscriber_db IS NOT NULL
    BEGIN
		-- The @subscriber and @subscriber_db parameter(s) have been deprecated and should no longer be used. See the 'sp_addpullsubscription_agent' documentation for more information.
		RAISERROR(21827, 10, -1, '@subscriber and @subscriber_db', 'sp_addmergepullsubscription_agent')
    END
    
   	SELECT @subscriber = @@SERVERNAME,
			@subscriber_db = DB_NAME()

    EXECUTE @retcode = sys.sp_validname @subscriber
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

    EXECUTE @retcode = sys.sp_validname @subscriber_db
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

    /* 
    ** Parameter check: @alt_snapshot_folder 
    ** @alt_snapshot_folder and @use_ftp are mutually exclusive    
    ** @dynamic_snapshot_location is incompatible with both 
    ** @alt_snapshot_folder and @use_ftp
    */

    IF @alt_snapshot_folder <> N'' AND @alt_snapshot_folder IS NOT NULL
    BEGIN
        IF LOWER(@use_ftp collate SQL_Latin1_General_CP1_CS_AS) = N'true'
        BEGIN
            RAISERROR(21146, 16, -1)
            RETURN (1)
        END
        IF @dynamic_snapshot_location <> N'' AND @dynamic_snapshot_location IS NOT NULL
        BEGIN
            RAISERROR(21341, 16, -1)
            RETURN (1)
        END
    END

    /*
    ** Parameter Check: @use_interactive_resolver  
    */
    if LOWER(@use_interactive_resolver collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@use_interactive_resolver')
            RETURN (1)
        END
    if LOWER(@use_interactive_resolver collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        set @use_interactive_bit = 1
    else 
        set @use_interactive_bit = 0

    /* 
    ** Parameter check: @use_ftp
    ** Must be 'true' or 'false'
    */
    IF LOWER(@use_ftp collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@use_ftp')
        RETURN (1)
    END
    
    IF LOWER(@use_ftp collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        /*
        ** Ftp file transfer is incompatible with @dynamic_snapshot_location
        */
        IF @dynamic_snapshot_location <> N'' AND @dynamic_snapshot_location IS NOT NULL
        BEGIN
            RAISERROR (21342, 16, -1)
            RETURN (1)
        END

        SELECT @use_ftp_bit = 1

    END
    ELSE
    BEGIN
        SELECT @use_ftp_bit = 0
    END

    /*
    ** Parameter Check: @offloadserver
    */
	IF @offloadagent IS NOT NULL
		AND RTRIM(LTRIM(LOWER(@offloadagent))) != 'false'
	BEGIN
		-- "Parameter '@offloadagent' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadagent')
		RETURN 1
	END

	IF ISNULL(@offloadserver, N'') != N''
	BEGIN
		-- "Parameter '@offloadserver' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadserver')
		RETURN 1
	END    
	
    -- Make sure that there are no leading or trailing blanks
    -- in the dynamic snapshot location
    select @dynamic_snapshot_location = rtrim(ltrim(@dynamic_snapshot_location))

    select @subscription_type_id = 1 /* pull agent only */
    /*
    ** Set Default schedule values if NULL is specified
    ** The default are not implemented during parmeter defintion because this procedure
    ** is can be called from sp_addmergesubscription.
    */
    if @frequency_type is NULL
        set @frequency_type = 4        /* Daily */
    if @frequency_interval is NULL
        set @frequency_interval = 1
    if @frequency_relative_interval is NULL
        set @frequency_relative_interval = 1
    if @frequency_recurrence_factor is NULL
        set @frequency_recurrence_factor = 0
    if @frequency_subday is NULL
        set @frequency_subday = 8    /* Hour */
    if @frequency_subday_interval is NULL
        set @frequency_subday_interval = 1
    if @active_start_time_of_day is NULL
        set @active_start_time_of_day = 0
    if @active_end_time_of_day is NULL
        set @active_end_time_of_day = 235959
    if @active_start_date is NULL
        set @active_start_date = 0
    if @active_end_date is NULL
        set @active_end_date = 99991231
            
    select @pubid = pubid from dbo.sysmergepublications 
        where name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db
    IF @pubid is NULL
    begin
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    end

    select @repid = subid, @subscription_type_id = subscription_type from dbo.sysmergesubscriptions
        where subscriber_server = @subscriber and pubid<>subid and pubid = @pubid and db_name = @subscriber_db
    if @subscription_type_id = 0
    begin
        -- can add an agent only for pull, anonymous or lighweight subscriptions
        -- cannot add an agent for a push subscription
        RAISERROR (20635, 16, -1, @publication)
        RETURN (1)
    end
    
	-- Check if the agent already exists.
	IF EXISTS(SELECT * 
				FROM dbo.MSmerge_replinfo msmr
			        JOIN msdb.dbo.sysjobs  sj
			        	ON msmr.merge_jobid = sj.job_id
		        WHERE repid = @repid)
	BEGIN
		SELECT @job_name = sj.name
			FROM dbo.MSmerge_replinfo msmr
		        JOIN msdb.dbo.sysjobs sj
		        	ON msmr.merge_jobid = sj.job_id
	        WHERE repid = @repid
	        
		-- A replication agent job for this subscription already exists.
		RAISERROR(21837, 11, -1, @job_name)
		RETURN 1
	END

	-- Parameter check: @subscriber_security_mode, @subscriber_login, @subscriber_password 
    IF (@subscriber_security_mode IS NOT NULL
    		AND @subscriber_security_mode <> 1)
    	OR @subscriber_login IS NOT NULL
    	OR @subscriber_password IS NOT NULL
    BEGIN
		-- The @subscriber_security_mode, @subscriber_login and @subscriber_password parameter(s) have been deprecated and should no longer be used. See the 'sp_addpullsubscription_agent' documentation for more information.
		RAISERROR(21827, 10, -1, '@subscriber_security_mode, @subscriber_login and @subscriber_password', 'sp_addmergepullsubscription_agent')
    END

	-- if we do not require yukon security then check paramters.
	IF sys.fn_yukonsecuritymodelrequired(NULL) = 0
	BEGIN
		IF @job_login IS NULL
		BEGIN
			IF @job_password IS NOT NULL
			BEGIN
				-- Parameter '@job_login' can be set to 'NULL' only when '@job_password' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_login', 'NULL', '@job_password', 'NULL')
				RETURN 1
			END
		END
		ELSE
		BEGIN
			IF @job_password IS NULL
			BEGIN
				-- Parameter '@job_password' can be set to 'NULL' only when '@job_login' is set to 'NULL'.
				RAISERROR(21678, 16, -1, '@job_password', 'NULL', '@job_login', 'NULL')
				RETURN 1
			END

			IF @edition_id <> 40 and @edition_id <> 22
				AND sys.fn_replisvalidwindowsloginformat(@job_login) != 1
			BEGIN
				-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addmergepullsubscription_agent'.
				RAISERROR(21797, 16, -1, '@job_login', 'sp_addmergepullsubscription_agent')
				RETURN 1
			END
		END
	END
	-- if yukon sec required then a valid windows login/password is required
	ELSE
	BEGIN
		IF @job_login IS NULL
			OR @job_password IS NULL
		BEGIN
			-- Only members of the sysadmin fixed server role can perform this operation without specifying @job_login or @job_password.
			RAISERROR(21832, 16, -1, '@job_login or @job_password')
			RETURN 1
		END

		IF @edition_id <> 40 and @edition_id <> 22
			AND sys.fn_replisvalidwindowsloginformat(@job_login) != 1
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addmergepullsubscription_agent'.
			RAISERROR(21797, 16, -1, '@job_login', 'sp_addmergepullsubscription_agent')
			RETURN 1
		END
	END
	
	
	-- Subscriber must be Windows Authentication
	SELECT @subscriber_security_mode = 1,
			@subscriber_login = N'',
			@subscriber_password = N'**********',
			@subscriber_enc_password = @subscriber_password

    EXEC @retcode = sys.sp_MSreplencrypt @subscriber_enc_password OUTPUT
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1

    -- default to Windows Auth.
    SELECT @publisher_security_mode = ISNULL(@publisher_security_mode, 1)
    
    -- check security mode
    IF @publisher_security_mode not in (0, 1)
    BEGIN
        -- The specified '@publisher_security_mode' is invalid (valid values are: 0, 1).
        RAISERROR(14266, 16, -1, '@publisher_security_mode', '0, 1')
        RETURN 1
    END

    -- make sure that the login is valid
    SELECT @publisher_login = RTRIM(LTRIM(ISNULL(@publisher_login, '')))

    -- Publisher Security Mode 1
    IF @publisher_security_mode = 1
    BEGIN
        SELECT @publisher_login = '',
                @publisher_password = newid()
    END
    -- Publisher Security Mode 0
    ELSE IF @publisher_login = ''
    BEGIN
        RAISERROR(21694, 16, -1, '@publisher_login', '@publisher_security_mode')
        RETURN 1
    END

    -- Encrypt Publisher Password
     SELECT @publisher_enc_password = @publisher_password
     
    EXEC @retcode = sys.sp_MSreplencrypt @publisher_enc_password OUTPUT
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1

    -- default to Windows Auth.
    SELECT @distributor_security_mode = ISNULL(@distributor_security_mode, 1)
    
    -- check security mode
    IF @distributor_security_mode not in (0, 1)
    BEGIN
        -- The specified '@distributor_security_mode' is invalid (valid values are: 0, 1).
        RAISERROR(14266, 16, -1, '@distributor_security_mode', '0, 1')
        RETURN 1
    END

    -- make sure that the login is valid
    SELECT @distributor_login = RTRIM(LTRIM(ISNULL(@distributor_login, '')))

    -- Distributor Security Mode 1
    IF @distributor_security_mode = 1
    BEGIN
        SELECT @distributor_login = '',
                @distributor_password = newid()
    END
    -- Distributor Security Mode 0
    ELSE IF @distributor_login = ''
    BEGIN

        -- '@distributor_login cannot be null or empty when @distributor_security_mode is set to 0 (SQL Server authentication).'
        RAISERROR(21694, 16, -1, '@distributor_login', '@distributor_security_mode')
        RETURN 1
    END

    -- Encrypt Distributor Password
     SELECT @distributor_enc_password = @distributor_password
     
    EXEC @retcode = sys.sp_MSreplencrypt @distributor_enc_password OUTPUT
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1
        
    select @internet_login = rtrim(ltrim(isnull(@internet_login, '')))
    if @internet_security_mode = 0 and @internet_login = ''
    begin
        -- '@internet_login cannot be null or empty when @internet_security_mode is set to 0 (SQL Server authentication).'
        raiserror(21694, 16, -1, '@internet_login', '@internet_security_mode')
        return 1
    end
    
    IF object_id('MSsubscription_properties','U') is NULL
    begin
        raiserror(14027, 16, -1, 'The subscription properties table ''MSsubscription_properties''')
        return (1)
    end
    
    declare @job_existing bit
    -- For scripting
    if @job_name is null
        select @job_existing = 0
    else
    begin
        select @job_existing = 1
        select @name = @job_name
    end

    /*
    ** Construct unique task name if @name = NULL
    */
    IF @name IS NULL
   	BEGIN
   		SELECT @name = CONVERT(nvarchar(23),@publisher ) + '-' + CONVERT(nvarchar(23),@publisher_db) + '-' + 
                        CONVERT(nvarchar(23),@publication) + '-' + CONVERT(nvarchar(23),@subscriber) + '-' +
                        CONVERT(nvarchar(23), @subscriber_db) + '- 0'

		IF EXISTS (SELECT * 
				FROM msdb.dbo.sysjobs_view 
				WHERE name = @name)
		BEGIN
			SELECT @name = sys.fn_repluniquename(newid(), 
													@publisher, 
													@publisher_db, 
													@publication,
													@subscriber_db)
		END			
    END

    begin tran
    save tran sp_pullsub_agent

    if @job_existing = 0
    begin
        
        -- Get subscriber port number
        declare @subscriber_with_port sysname
        exec sys.sp_MSget_server_portinfo 
            @name = @@SERVERNAME,
            @srvname_with_port = @subscriber_with_port OUTPUT

        /* Construct task command */
        select @command = '-Publisher ' + QUOTENAME(@publisher_with_port) + ' -PublisherDB ' + QUOTENAME(@publisher_db) + ' '
        select @command = @command + '-Publication ' + QUOTENAME(@publication) + ' '
        select @command = @command + '-Subscriber ' + QUOTENAME(@subscriber_with_port)  + ' '
        select @command = @command + '-SubscriberDB ' + QUOTENAME(db_name()) + ' '
        SELECT @command = @command + '-SubscriptionType ' + convert(nvarchar(10), @subscription_type_id)  + ' '

        -- Always use integrated for local security
        select @command = @command + '-SubscriberSecurityMode 1 ' 
        
        select @command = @command + @optional_command_line
        select @command = @command + ' -Distributor ' + QUOTENAME(@distributor_with_port) + ' '
        
        select @dynamic_snapshot_location = rtrim(ltrim(@dynamic_snapshot_location))
        if @dynamic_snapshot_location is not null and 
           @dynamic_snapshot_location <> N''
            select @command = @command + N'-DynamicSnapshotLocation ' + sys.fn_replquotename(@dynamic_snapshot_location, default) collate database_default + N' '

        select @internet_url = rtrim(ltrim(@internet_url))
        --if @internet_url is not null and 
          -- @internet_url <> N''
            --select @command = @command + N'-WebSync 1 '
            
        -- Don't need to add InternetURL, InternetLogin, InternetPassword, InternetSecurityMode and Hostname
        -- to the command line. This is because we want to allow those properties to be easily changed
        -- in the MSsubscription_properties table (as opposed to updating command line args in sysjobsteps).

        -- Get Merge category name (assumes category_id = 14)
        select @category_name = name FROM msdb.dbo.syscategories where category_id = 14

        EXEC @retcode = sys.sp_MSadd_repl_job
                @name = @name,
                @subsystem = 'Merge',
                @server = @@SERVERNAME,
                @databasename = @subscriber_db,
                @enabled = 1,
                @freqtype = @frequency_type,
                @freqinterval = @frequency_interval,
                @freqsubtype = @frequency_subday,
                @freqsubinterval = @frequency_subday_interval,
                @freqrelativeinterval = @frequency_relative_interval,
                @freqrecurrencefactor = @frequency_recurrence_factor,
                @activestartdate = @active_start_date,
                @activeenddate = @active_end_date,
                @activestarttimeofday = @active_start_time_of_day,
                @activeendtimeofday = @active_end_time_of_day,
                @command = @command,
                @retryattempts = 10,
                @retrydelay = 1,
                @category_name = @category_name,
                @job_id = @merge_jobid OUTPUT,
                @job_step_uid = @merge_job_step_uid OUTPUT,
                @job_login = @job_login,
                @job_password = @job_password

        if @@ERROR <> 0 or @retcode <> 0 goto Rollback_tran
    end
    else
    begin
        SELECT @merge_jobid = sjv.job_id,
                    @merge_job_step_uid = sjs.step_uid
            FROM msdb.dbo.sysjobs_view as sjv 
                JOIN msdb.dbo.sysjobsteps as sjs 
                    ON sjv.job_id = sjs.job_id 
            WHERE sjv.name = @job_name collate database_default 
                AND UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
                AND sjv.master_server = 0
                AND sjv.category_id = 14
                AND sjs.subsystem = N'Merge'
                AND sjs.database_name = db_name()
        
        if @merge_jobid IS NULL
        begin
            -- Message from msdb.dbo.sp_verify_job_identifiers
            RAISERROR(14262, -1, -1, 'Job', @name)          
            goto Rollback_tran
        end
    end

    if (@subscription_type_id = 1) OR (@subscription_type_id = 2) OR (@subscription_type_id = 3)
    begin
        IF NOT EXISTS (select * from MSsubscription_properties 
            where UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication) 
        BEGIN
            -- We no longer supported passing in encrypted passwords
            IF @encrypted_password = 1
            BEGIN
                -- Parameter '@encrypted_password' is no longer supported.
                RAISERROR(21698, 16, -1, '@encrypted_password')
                goto Rollback_tran
            END
    
            IF @publisher_encrypted_password = 1
            BEGIN
                -- Parameter '@publisher_encrypted_password' is no longer supported.
                RAISERROR(21698, 16, -1, '@publisher_encrypted_password') 
                goto Rollback_tran
            END

		    -- Encrypt Distributor Password
		    SELECT @internet_enc_password = @internet_password
		    
            EXEC @retcode = sys.sp_MSreplencrypt @internet_enc_password OUTPUT
            IF @@error <> 0 OR @retcode <> 0 goto Rollback_tran
              
            INSERT INTO MSsubscription_properties 
            (publisher, publisher_db, publication, publication_type, 
             publisher_login,publisher_password, publisher_security_mode, 
             distributor, distributor_login, distributor_password, 
             distributor_security_mode, ftp_address, ftp_port, ftp_login, 
             ftp_password, alt_snapshot_folder, working_directory, use_ftp,
             offload_agent, offload_server, dynamic_snapshot_location, use_web_sync, internet_url,
             internet_login, internet_password, internet_security_mode, internet_timeout, hostname, job_step_uid)
            values 
            (@publisher, @publisher_db, @publication, 2, @publisher_login, 
             @publisher_enc_password, @publisher_security_mode, @distributor, 
             @distributor_login, @distributor_enc_password, 
             @distributor_security_mode, null, null, null,
             null, @alt_snapshot_folder, @working_directory, @use_ftp_bit,
             0, null, @dynamic_snapshot_location, @use_web_sync, @internet_url,
             @internet_login, @internet_enc_password, @internet_security_mode, @internet_timeout, @hostname, @merge_job_step_uid)
            IF @@ERROR <> 0 goto Rollback_tran
        END
        ELSE
        BEGIN
			 UPDATE MSsubscription_properties SET  
				 	distributor = @distributor,
	                distributor_login = @distributor_login,
	                distributor_password = @distributor_enc_password,
	                distributor_security_mode = @distributor_security_mode,
	                publisher_login = @publisher_login,
	                publisher_password = @publisher_enc_password,
	                publisher_security_mode = @publisher_security_mode,
	                job_step_uid = @merge_job_step_uid
                WHERE UPPER(publisher) = UPPER(@publisher)
                    AND publisher_db =  @publisher_db
                    AND publication = @publication
        END
    end

    /* Update merge jobid for this pull subscription */
    UPDATE dbo.MSmerge_replinfo 
        set merge_jobid = @merge_jobid,
            use_interactive_resolver = @use_interactive_bit
        WHERE repid = @repid
    
    /* Conditional support for MobileSync */
    if LOWER(@enabled_for_syncmgr collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        /* Call sp_MSregistersubscription so that the subscription can be synchronized via MobileSync etc. */
        exec @retcode = sys.sp_MSregistersubscription @replication_type = 2,
                                    @publisher = @publisher,
                                    @publisher_security_mode = @publisher_security_mode,
                                    @publisher_login = @publisher_login,
                                    @publisher_password = @publisher_password,
                                    @publisher_db = @publisher_db,
                                    @publication = @publication,
                                    @subscriber = @subscriber,
                                    @subscriber_db = @subscriber_db,
                                    @subscriber_security_mode = @subscriber_security_mode,
                                    @subscriber_login = @subscriber_login,
                                    @subscriber_password = @subscriber_password,
                                    @distributor = @distributor,
                                    @distributor_security_mode = @distributor_security_mode,
                                    @distributor_login = @distributor_login,
                                    @distributor_password = @distributor_password,
                                    @subscription_id = @repid,
                                    @subscription_type = @subscription_type_id,
                                    @use_interactive_resolver = @use_interactive_bit,
                                    @use_web_sync = @use_web_sync,
                                    @hostname = @hostname

        IF @@ERROR <> 0 or @retcode <> 0 goto Rollback_tran
    END

	-- If we didn't need to create the job but 
	-- we were given the job_login and job_password
	-- then we will attempt to change them or add
	-- NOTE:
	-- We do this at the very end because the actual
	-- agent must be added prior to setting the login
	-- and passwords...
	IF @job_existing = 1
	BEGIN
		IF @job_login IS NOT NULL
		BEGIN
			EXEC @retcode = sys.sp_change_subscription_properties @publisher = @publisher,
																	@publisher_db = @publisher_db,
																	@publication = @publication,
																    @property = 'merge_job_login',
																	@value = @job_login
			IF @retcode <> 0 OR @@ERROR <> 0
	            goto Rollback_tran

			EXEC @retcode = sys.sp_change_subscription_properties @publisher = @publisher,
																	@publisher_db = @publisher_db,
																	@publication = @publication,
																    @property = 'merge_job_password',
																	@value = @job_password
			IF @retcode <> 0 OR @@ERROR <> 0
		    	goto Rollback_tran
		END
	END
	
commit tran
    RETURN (0)
Rollback_tran:
    rollback tran sp_pullsub_agent
    commit tran
    return (1)
END
GO
GRANT EXECUTE ON [sys].[sp_addmergepullsubscription_agent] TO [public] AS [dbo]
GO
