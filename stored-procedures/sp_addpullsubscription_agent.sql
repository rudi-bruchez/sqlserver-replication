SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addpullsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addpullsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addpullsubscription_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_security_mode [int],
	@subscriber_login [sysname],
	@subscriber_password [sysname],
	@distributor [sysname],
	@distribution_db [sysname],
	@distributor_security_mode [int],
	@distributor_login [sysname],
	@distributor_password [sysname],
	@optional_command_line [nvarchar](4000),
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
	@distribution_jobid [binary](16) OUTPUT,
	@encrypted_distributor_password [bit],
	@enabled_for_syncmgr [nvarchar](5),
	@ftp_address [sysname],
	@ftp_port [int],
	@ftp_login [sysname],
	@ftp_password [sysname],
	@alt_snapshot_folder [nvarchar](255),
	@working_directory [nvarchar](255),
	@use_ftp [nvarchar](5),
	@publication_type [tinyint],
	@dts_package_name [sysname],
	@dts_package_password [sysname],
	@dts_package_location [nvarchar](12),
	@reserved [nvarchar](100),
	@offloadagent [nvarchar](5),
	@offloadserver [sysname],
	@job_name [sysname],
	@job_login [nvarchar](257),
	@job_password [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    /*
    ** Declarations.
    */

    DECLARE @command                    nvarchar(4000)
                ,@retcode                    int
                ,@subscription_type_id       int                    -- 1 = pull, 2 = anonymous
                ,@independent_agent_id       bit
                ,@distribution_agent         nvarchar(100) 
                ,@category_name              sysname
                ,@platform_nt                binary
                ,@subscriber_enc_password    nvarchar(524)
                ,@distributor_enc_password   nvarchar(524)
                ,@use_ftp_bit                bit
                ,@distribution_job_step_uid  uniqueidentifier
                ,@edition_id				 int
                ,@prefailover_distribution_agent bit
                ,@error_id					 int
                ,@permission_issue			 bit

    select @platform_nt = 0x1
            ,@distribution_job_step_uid = NULL
            ,@edition_id = sys.fn_MSrepl_editionid ()
            ,@prefailover_distribution_agent = 0

    /*
    ** Security Check
    */

    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
    
    /*
    ** Initializations.
    */

    -- Set null @optional_command_line to empty string to avoid string concat problem
    if @optional_command_line is null
        set @optional_command_line = ''
    else
        set @optional_command_line = N' ' + LTRIM( RTRIM(@optional_command_line) ) + N' '


    IF @distributor_password = N''
        select @distributor_password = NULL

    IF @ftp_password = N''
        select @ftp_password = NULL

    IF @dts_package_password = N''
        select @dts_package_password = NULL

    -- @dts_package_password cannot be non-null if @dts_package_name is not set
    if (@dts_package_name is null or rtrim(@dts_package_name) = N'') and
        @dts_package_password is not null
    begin
        raiserror(18780, 16, -1)
        return (1)
    end
    
    IF RTRIM(ISNULL(@dts_package_name, N'')) != N''
        AND RTRIM(ISNULL(@dts_package_password, N'')) = N''
    BEGIN
        -- Use of DTS packages in replication requires a non-NULL/non-empty string password. Specify a valid value for parameter '%s'.
        RAISERROR(21732,16, -1, '@dts_package_password')
        RETURN (1)
    END

    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is define
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_addpullsubscription_agent')
        RETURN (1)
    END

    EXECUTE @retcode = sys.sp_validname @publisher

    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

	-- ensure that the distributor is set to a value... 
	-- we will default to publisher since this is sp default
	SELECT @distributor = ISNULL(@distributor, @publisher)
	
    -- Get publisher port number
    DECLARE @publisher_with_port sysname
    EXEC sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT,
        @srvname_with_port = @publisher_with_port OUTPUT

    -- Get distributor port number
    DECLARE @distributor_with_port sysname
    EXEC sys.sp_MSget_server_portinfo 
        @name = @distributor, 
        @srvname = @distributor OUTPUT,
        @srvname_with_port = @distributor_with_port OUTPUT

    /*
    ** Parameter Check: @publisher_db
    */
    IF @publisher_db = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    IF @publisher_db IS NOT NULL
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher_db
        IF @@ERROR <> 0 OR @retcode <> 0
            RETURN (1)
    END
    ELSE
    BEGIN
        -- @publisher_db is NULL for Oracle publishers only
        SET @publisher_db = @publisher
    END

    /*
    ** Parameter Check: @publication
    ** 
    */
    IF @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_addpullsubscription_agent')
        RETURN (1)
    END

    EXECUTE @retcode = sys.sp_validname @publication

    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

    /*
    ** Parameter Check: @subscriber and @subscriber_db
    */

    IF @subscriber_db IS NOT NULL
    BEGIN
        --The @subscriber_db parameter(s) have been deprecated and should no longer be used. See the 'sp_addpullsubscription_agent' documentation for more information.
        RAISERROR(21827, 10, -1, '@subscriber_db', 'sp_addpullsubscription_agent')
    END

    SELECT @subscriber_db = DB_NAME()

    SELECT @subscriber = ISNULL(@subscriber, @@SERVERNAME), @error_id = NULL, @permission_issue = 0

    IF @subscriber <> @@SERVERNAME
    BEGIN
        IF (SERVERPROPERTY('EngineEdition') <> 8 )		--Check AG DMV when its not Managed Instance 
        BEGIN
            BEGIN TRY
                IF NOT EXISTS (SELECT * FROM sys.availability_group_listeners AGL														--  subscriber isn't the listener name of the AG
                                INNER JOIN sys.dm_hadr_database_replica_states DBRepl ON AGL.group_id = DBRepl.group_id
                                WHERE DBRepl.database_id = DB_ID(@subscriber_db)
                                AND UPPER(AGL.dns_name) = UPPER(@subscriber collate database_default))
                BEGIN
                    -- The @subscriber parameter must be either @@SERVERNAME or listener name of the availability group that the subscriber database is part of.
                    SELECT @error_id = 25037
                END
            END TRY
            BEGIN CATCH
                --User needs to have VIEW SERVER STATE permission to assign @subscriber as the listener name of the availability group.
                IF (ERROR_NUMBER() = 300)-- The user does not have permission to perform this action. 
                BEGIN
                    SELECT @error_id = 25038
                    SELECT @permission_issue = 1
                END
                ELSE
                BEGIN
                    DECLARE @sev int
                        ,@state int
                        ,@msg nvarchar(max)
                    SELECT @sev = ERROR_SEVERITY(), @state = ERROR_STATE(), @msg = ERROR_MESSAGE()
                    RAISERROR(@msg, @sev, @state)
                    RETURN (1)
                END
            END CATCH
        END
        ELSE
        BEGIN				--For Managed Instance scenario, fall back to @@SERVERNAME
            -- Assigning listener name for @subscriber parameter is not a supported scenario for Managed Instance.
            SELECT @error_id = 25039
        END
    END

    IF @error_id IS NOT NULL
    BEGIN
        RAISERROR(@error_id, 10, -1)
        SELECT @subscriber = @@SERVERNAME
        --Assigning the default value to "%ls": %ls.
        RAISERROR(25040, 10, -1, N'@subscriber', N'@@SERVERNAME')
    END
    
    EXECUTE @retcode = sys.sp_validname @subscriber
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)
    
    EXECUTE @retcode = sys.sp_validname @subscriber_db
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)
    
    /* 
    ** Check to see if MSreplictaion_subscriptions table exists.
    ** If so, copy it into the temp table
    */
    IF object_id('MSreplication_subscriptions', 'U') is NULL
    BEGIN
        RAISERROR (20017, 16, -1)
        RETURN (1)
    END 
    
    /*
    ** Check to make sure that the subscription does exist
    */
    IF NOT EXISTS (SELECT * FROM  MSreplication_subscriptions
                WHERE UPPER(publisher) = UPPER(@publisher) AND
                      publisher_db  = @publisher_db AND
                      publication = @publication)
    BEGIN
        RAISERROR (20017, 16, -1)
        RETURN (1)
    END
    
    declare @update_mode_id int
    SELECT  @distribution_agent = NULL
    SELECT  @independent_agent_id = independent_agent, 
            @subscription_type_id = subscription_type,
            @distribution_agent = distribution_agent,
            @update_mode_id = update_mode
        FROM  MSreplication_subscriptions
        WHERE UPPER(publisher) = UPPER(@publisher) AND
              publisher_db  = @publisher_db AND
              publication = @publication
    /* Distribution agent for push subscriptions is at distributor side */
    IF @subscription_type_id = 0
    BEGIN
        RAISERROR (21001, 16, -1)
        RETURN (1)
    END

    IF @distribution_agent IS NOT NULL
    BEGIN
        IF(@subscription_type_id = 1			-- pull subscription
                AND NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs_view as sjv		--no existing distribution agent job on the server for the subscriber_db
                                    JOIN msdb.dbo.sysjobsteps as sjs 
                                    ON sjv.job_id = sjs.job_id 
                                    WHERE UPPER(sjv.name) = UPPER(@distribution_agent collate database_default) 
                                    AND UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
                                    AND sjs.subsystem = N'Distribution'
                                    AND UPPER(sjs.database_name) = UPPER(@subscriber_db))
                AND @permission_issue = 0 AND EXISTS (SELECT * FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID(@subscriber_db))	)	--subscriber_db is part of AG
        BEGIN
            SELECT @job_name = @distribution_agent, @prefailover_distribution_agent = 1
        END
        ELSE
        BEGIN
            RAISERROR (21002, 11, -1, @distribution_agent)
            RETURN (1)
        END
    END
    
    -- Parameter check: @subscriber_security_mode, @subscriber_login, @subscriber_password 
    IF (@subscriber_security_mode IS NOT NULL
        AND @subscriber_security_mode <> 1)
        OR @subscriber_login IS NOT NULL
        OR @subscriber_password IS NOT NULL
    BEGIN
        -- The @subscriber_security_mode, @subscriber_login and @subscriber_password parameter(s) have been deprecated and should no longer be used. See the 'sp_addpullsubscription_agent' documentation for more information.
        RAISERROR(21827, 10, -1, '@subscriber_security_mode, @subscriber_login and @subscriber_password', 'sp_addpullsubscription_agent')
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
				AND @edition_id <> 32 -- CL edition uses @job_login for SQL authentication, so no needs to validate it as windows one
				AND sys.fn_replisvalidwindowsloginformat(@job_login) != 1
			BEGIN
				-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addpullsubscription_agent'.
				RAISERROR(21797, 16, -1, '@job_login', 'sp_addpullsubscription_agent')
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
			AND @edition_id <> 32 -- CL edition uses @job_login for SQL authentication, so no needs to validate it as windows one
			AND sys.fn_replisvalidwindowsloginformat(@job_login) != 1
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_addpullsubscription_agent'.
			RAISERROR(21797, 16, -1, '@job_login', 'sp_addpullsubscription_agent')
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

    -- Security Mode = 1
    IF @distributor_security_mode = 1
    BEGIN
        SELECT @distributor_login = '',
                @distributor_password = newid()
    END
    -- Security Mode = 0
    ELSE IF @distributor_login = ''
    BEGIN

        -- '@distributor_login cannot be null or empty when @distributor_security_mode is set to 0 (SQL Server authentication).'
        RAISERROR(21694, 16, -1, '@distributor_login', '@distributor_security_mode')
        RETURN 1
    END

    SELECT @distributor_enc_password = @distributor_password
        
    EXEC @retcode = sys.sp_MSreplencrypt @distributor_enc_password OUTPUT
    IF @@ERROR <> 0 OR @retcode <> 0
        RETURN 1
    
    IF object_id('MSsubscription_properties','U') is NULL
    begin
        exec @retcode = sys.sp_MScreate_sub_tables_internal @property_table = 1
        if @retcode <> 0 or @@error <> 0
        return (1)
    end

    /* 
    ** Parameter check: @alt_snapshot_folder 
    ** @alt_snapshot_folder and @use_ftp are mutually exclusive    
    */

    IF @alt_snapshot_folder <> N'' AND @alt_snapshot_folder IS NOT NULL
       AND LOWER(@use_ftp collate SQL_Latin1_General_CP1_CS_AS) = N'true'
    BEGIN
        RAISERROR(21146, 16, -1)
        RETURN (1)
    END

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
        SELECT @use_ftp_bit = 1
    END
    ELSE
    BEGIN
        SELECT @use_ftp_bit = 0
    END


    /*
    ** Parameter check: @publication_type
    ** Must be 0 - Transactional or 1 - Snapshot
    */
    IF @publication_type NOT IN (0, 1)
    BEGIN
        RAISERROR (20033, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check: @dts_package_location
    ** Valid values:
    ** distributor
    ** subscriber
    **
    */
    IF LOWER(@dts_package_location collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('distributor', 'subscriber')
    BEGIN
        RAISERROR(21179, 16, -1)    
        RETURN (1)
    END

    declare @dts_package_location_id int

    IF LOWER(@dts_package_location collate SQL_Latin1_General_CP1_CS_AS) = 'distributor'
        SELECT @dts_package_location_id = 0
    ELSE 
        SELECT @dts_package_location_id = 1

    -- Have to be a push, non updatable  subscription to set DTS package name
    if @dts_package_name is not null
    begin
        if  @update_mode_id != 0
        begin
            RAISERROR(21180, 16, -1)    
            RETURN (1)
        end
    end
    
    -- Copy the passwords to new value before attempting to encrypt
    -- We no longer supported passing in encrypted passwords
    IF @encrypted_distributor_password = 1
    BEGIN
        -- Parameter '@encrypted_distributor_password' is no longer supported.
        RAISERROR(21698, 16, -1, '@encrypted_distributor_password')
        RETURN (1)
    END
    
    declare @dts_package_enc_password nvarchar(524)
    set @dts_package_enc_password = @dts_package_password

    if @dts_package_enc_password is not null
    begin
        EXEC @retcode = sys.sp_MSreplencrypt @dts_package_enc_password OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1
    end

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

    /*
    ** Construct unique name
    */
    if @subscriber is NULL select @subscriber = ''
    if @subscriber_db is NULL select @subscriber_db = ''
    
    declare @job_existing bit
    if @job_name is null
    begin
        select @job_existing = 0
        SELECT @job_name = CONVERT(nvarchar(18),@publisher ) + '-' + 
                        CASE @publisher_db
                            WHEN NULL THEN ''
                            ELSE CONVERT(nvarchar(18),@publisher_db) + '-'
                        END + 
                        CONVERT(nvarchar(18),@publication) + '-' + CONVERT(nvarchar(18),@subscriber) + '-' +
                        CONVERT(nvarchar(18),@subscriber_db) + '-' + CONVERT(nvarchar(36),newid())
    end
    else
        SELECT @job_existing = case @prefailover_distribution_agent when  1 then 0 else 1 end			--for subscriptions with distribution_agent specified without a job (and in AG), just use the @job_name as the the name and create the job
	
    -- Cloud Lifter edition (CL) uses values provided through @job_login and @job_password
    -- for SQL authentication (Windows authentication and proxies are not supported in CL)
    DECLARE @cl_login nvarchar(257), @cl_password nvarchar(524)
    IF sys.fn_MSrepl_editionid() = 32 AND @job_login IS NOT NULL AND @job_password IS NOT NULL
    BEGIN
        -- @job_login and @job_password should be nullified to avoid use of them for proxy configuration
        SELECT @cl_login = @job_login, @cl_password = @job_password, @job_login = NULL, @job_password = NULL
        -- Encrypt the password before storing
        EXEC @retcode = sys.sp_MSreplencrypt @cl_password OUTPUT
        IF @@ERROR <> 0 OR @retcode <> 0
            RETURN 1
    END

    BEGIN TRAN
    save tran sp_addpullsubagent

    /*
    ** If the publication is independent agent type or it is the first
    ** subscription on the non independent agent publications.
    */

    IF @independent_agent_id = 1 OR 
        NOT EXISTS (SELECT * FROM MSreplication_subscriptions WHERE
                            UPPER(@publisher) = UPPER(publisher) and
                            @publisher_db = publisher_db and
                            agent_id IS NOT NULL and
                            independent_agent = 0)
    BEGIN
        if @job_existing = 0
        begin

            -- Get subscriber port number
            DECLARE @subscriber_with_port sysname
            EXEC sys.sp_MSget_server_portinfo 
                @name = @subscriber,
                @srvname_with_port = @subscriber_with_port OUTPUT

            /* Construct agent command */
            SELECT @command = '-Publisher ' + QUOTENAME(@publisher_with_port) + ' '

            IF @publisher_db IS NOT NULL
                SELECT @command = @command + '-PublisherDB ' + QUOTENAME(@publisher_db) + ' '
			
            IF @independent_agent_id = 1
                SELECT @command = @command + '-Publication ' + QUOTENAME(@publication) + ' '

            SELECT @command = @command + '-Distributor ' + QUOTENAME(@distributor_with_port)  + ' '

            SELECT @command = @command + '-SubscriptionType ' + convert(nvarchar(10),@subscription_type_id)  + ' '

            SELECT @command = @command + '-Subscriber ' + QUOTENAME(@subscriber_with_port)  + ' '

            -- Always use integrated for local security
            select @command = @command + '-SubscriberSecurityMode 1 '

            SELECT @command = @command + '-SubscriberDB ' + QUOTENAME(@subscriber_db) + ' '

            if @dts_package_name is not null
              select @command = @command + '-UseDTS '

            /* 
            ** make sure the command line is not truncated
            */
            /* Use datalength because len doesn't count the last space in @command */
            IF (datalength(@command) + datalength(@optional_command_line)) > 8000
            BEGIN
                RAISERROR(20018, 16, -1)
                goto cleanup
            END

            SELECT @command = @command + @optional_command_line

            -- Get Distribution category name (assumes category_id = 10)
            select @category_name = name FROM msdb.dbo.syscategories where category_id = 10

            EXEC @retcode = sys.sp_MSadd_repl_job
                    @name = @job_name,
                    @subsystem = 'Distribution',
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
                    @category_name = @category_name,
                    @retryattempts = 10,
                    @retrydelay = 1,
                    @job_id = @distribution_jobid OUTPUT,
                    @job_step_uid = @distribution_job_step_uid OUTPUT,
                    @job_login = @job_login,
                    @job_password = @job_password

            IF @@ERROR <> 0 or @retcode <> 0
                goto cleanup
        end
        else
        begin
            SELECT @distribution_jobid = sjv.job_id,
                    @distribution_job_step_uid = sjs.step_uid
            FROM msdb.dbo.sysjobs_view as sjv 
                JOIN msdb.dbo.sysjobsteps as sjs 
                    ON sjv.job_id = sjs.job_id 
            WHERE sjv.name = @job_name collate database_default 
                AND UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
                AND sjv.master_server = 0
                AND sjv.category_id = 10
                AND sjs.subsystem = N'Distribution'
                AND sjs.database_name = db_name()
                    
            if @distribution_jobid IS NULL
            begin
                -- Message from msdb.dbo.sp_verify_job_identifiers
                RAISERROR(14262, -1, -1, 'Job', @job_name)          
                goto cleanup
            end
        end
    END

        /* If we do not have independent agents , i.e. independent_agent=0, but there is
    already a row for that publisher and that publisher database with a NOT null 
    distribution_agent_id, then set the @distribution_jobid to that id.  Note that if
    there are no rows returned, the value of the variable does not change, which is what we want.
    There should never be more than one row ever returned for this query - but will use TOP 1
    to insist that is the case.
    */
    
    IF @independent_agent_id = 0
    BEGIN
        SELECT DISTINCT @distribution_jobid=agent_id, @job_name = distribution_agent
          FROM MSreplication_subscriptions
         WHERE UPPER(publisher) = UPPER(@publisher) 
           AND publisher_db =  @publisher_db
           AND agent_id IS NOT NULL AND independent_agent=0
    END
    
    UPDATE MSreplication_subscriptions 
       SET distribution_agent = @job_name,
           agent_id = @distribution_jobid
     WHERE UPPER(publisher) = UPPER(@publisher) 
       AND publisher_db =  @publisher_db 
       AND publication =  @publication 
       AND (subscription_type = 1 /* pull*/ OR subscription_type = 2) /*anonymous*/

    IF @@ERROR <> 0 
        goto cleanup

    if (@subscription_type_id = 1) OR (@subscription_type_id = 2)
    BEGIN
        -- if the job step uid is null then we will 
        -- attempt to retrieve it based on job info
        if @distribution_job_step_uid IS NULL
        begin
            select @distribution_job_step_uid = sjs.step_uid
            from msdb.dbo.sysjobs_view as sjv 
                join msdb.dbo.sysjobsteps as sjs 
                    on sjv.job_id = sjs.job_id 
            where sjv.job_id = @distribution_jobid
                and sjv.master_server = 0
                and UPPER(sjv.originating_server) = UPPER(CONVERT(sysname, SERVERPROPERTY('ServerName')))
                and sjv.category_id = 10
                and sjs.subsystem = N'Distribution' 
                and sjs.database_name = db_name()
        end
		
        IF NOT EXISTS (select * from MSsubscription_properties 
            where UPPER(publisher) = UPPER(@publisher)
              and publisher_db =  @publisher_db
              and publication = @publication) 
        BEGIN
            -- Publication type:
            -- 0  transactional
            -- 1  snapshot
            -- 2  merge (not allowed)

            INSERT INTO MSsubscription_properties 
            (publisher, publisher_db, publication, publication_type, 
             publisher_login,publisher_password, publisher_security_mode, 
             distributor, distributor_login, distributor_password, 
             distributor_security_mode, ftp_address, ftp_port, ftp_login, 
             ftp_password, alt_snapshot_folder, working_directory, use_ftp,
             dts_package_name, dts_package_password, dts_package_location, 
             offload_agent, offload_server, dynamic_snapshot_location, job_step_uid, job_login, job_password)
            values (@publisher, @publisher_db, @publication, @publication_type, NULL, NULL, -1, 
                @distributor, @distributor_login, @distributor_enc_password, 
                @distributor_security_mode, null, null, null,
                null, @alt_snapshot_folder, @working_directory, @use_ftp_bit,
                @dts_package_name, @dts_package_enc_password, 
                @dts_package_location_id, 0, null, null, @distribution_job_step_uid, @cl_login, @cl_password)
        END
        ELSE
        BEGIN
            update MSsubscription_properties set
                distributor = @distributor,
                distributor_login = @distributor_login,
                distributor_password = @distributor_enc_password,
                distributor_security_mode = @distributor_security_mode,
                dts_package_name = @dts_package_name,
                dts_package_password = @dts_package_enc_password,
                dts_package_location = @dts_package_location_id,
                job_step_uid = @distribution_job_step_uid,
                job_login = @cl_login,
                job_password = @cl_password
                where UPPER(publisher) = UPPER(@publisher)
                    and publisher_db =  @publisher_db
                    and publication = @publication
        END
        IF @@ERROR <> 0 
            goto cleanup


        -- For dependent subscriptions we need to fix up all the
        -- shared properties  
        IF @independent_agent_id = 0 
        BEGIN

            EXEC @retcode = sys.sp_MSfixupsharedagentproperties
                   @publisher = @publisher,
                   @publisher_db = @publisher_db,
                   @publication = @publication,
                   @distributor = @distributor,
                   @distributor_security_mode = @distributor_security_mode,
                   @distributor_login = @distributor_login,
                   @distributor_password = @distributor_enc_password,
                   @ftp_address = @ftp_address,
                   @ftp_port = @ftp_port,
                   @ftp_login = @ftp_login,
                   @ftp_password = @ftp_password,
                   @alt_snapshot_folder = @alt_snapshot_folder,
                   @working_directory = @working_directory,
                   @use_ftp = @use_ftp_bit
                   
            IF @retcode <> 0 OR @@ERROR <> 0
                goto cleanup
        END

        IF @@ERROR <> 0 
            goto cleanup
    END

    /* Conditional support for MobileSync */
    if LOWER(@enabled_for_syncmgr collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        /* Call sp_MSregistersubscription so that the subscription can be synchronized via MobileSync etc. */
        declare @subscription_id uniqueidentifier
        declare @failover_mode_id int
        set @subscription_id = convert(uniqueidentifier, @distribution_jobid)

        if @update_mode_id in (3,5) 
            select @failover_mode_id = 1
        else if @update_mode_id in (2,4)
            select @failover_mode_id = 2
        else
            select @failover_mode_id = 0
            
        exec @retcode = sys.sp_MSregistersubscription @replication_type = 1,
                                    @publisher = @publisher,
                                    @publisher_db = @publisher_db,
                                    @publication = @publication,
                                    @subscriber = @subscriber,
                                    @subscriber_db = @subscriber_db,
                                    @subscriber_security_mode = @subscriber_security_mode,
                                    @subscriber_login = @subscriber_login,
                                    @subscriber_password = @subscriber_password,
                                    @distributor = @distributor,
                                    @subscription_id = @subscription_id,
                                    @independent_agent = @independent_agent_id,
                                    @subscription_type = @subscription_type_id,
                                    @failover_mode = @failover_mode_id
        IF @@ERROR <> 0 or @retcode <> 0
            goto cleanup
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
																    @property = 'distrib_job_login',
																	@value = @job_login
			IF @retcode <> 0 OR @@ERROR <> 0
	            GOTO cleanup

			EXEC @retcode = sys.sp_change_subscription_properties @publisher = @publisher,
																	@publisher_db = @publisher_db,
																	@publication = @publication,
																    @property = 'distrib_job_password',
																	@value = @job_password
			IF @retcode <> 0 OR @@ERROR <> 0
		    	GOTO cleanup
		END
	END
	
    -- success
    COMMIT TRAN
    RETURN(0)
    -- error cleanup
cleanup:
    ROLLBACK TRAN sp_addpullsubagent
    COMMIT TRAN           
    RETURN(1)
END
GO
GRANT EXECUTE ON [sys].[sp_addpullsubscription_agent] TO [public] AS [dbo]
GO
