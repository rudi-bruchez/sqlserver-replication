SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_change_subscription_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_change_subscription_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_change_subscription_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@property [sysname],
	@value [nvarchar](1000),
	@publication_type [int]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @command            nvarchar(2000)
    DECLARE @column_to_update   nvarchar(64)
    DECLARE @value_string       nvarchar(2004)
    DECLARE @independent_agent  bit
    DECLARE @retcode            int
    DECLARE @subscription_type  int
    DECLARE @intvalue           int
    DECLARE @value_bit          bit
    DECLARE @dbname             sysname
    DECLARE @local_publication  sysname
    DECLARE @agentid            binary(16)
    DECLARE @job_step_uid       uniqueidentifier
    DECLARE @local_publisher    sysname
    DECLARE @cursor_opened      bit 
    DECLARE @cursor_allocated   bit
    DECLARE @agenttype          nvarchar(20)
    DECLARE @commandline        nvarchar(3200)
    DECLARE @password            nvarchar(524)
    DECLARE @proxy_id			int
    DECLARE @distributor 		sysname
	DECLARE @distribution_db 	sysname
	DECLARE @distproc 			nvarchar(1000)
	DECLARE @subscriber			sysname
	DECLARE @subscriber_db		sysname
    
    SELECT @cursor_opened = 0
    SELECT @cursor_allocated = 0
    SELECT @retcode = 0    
    /*
    ** Security Check
    */

    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
        
    if (@publisher is null)
    begin
        raiserror(14043, 16, -1, '@publisher', 'sp_change_subscription_properties')
        return (1)
    end

    if(@publisher_db is null)
    begin
        raiserror(14043, 16, -1, '@publisher_db', 'sp_change_subscription_properties')
        return (1)
    end

    if (@publication is null) or (@publication = '')
    begin
        select @publication = '%'
    end

    -- The following check should only be performed on a merge subscriber
    if 	@publication_type = 2 and 
    	object_id('sysmergesubscriptions', 'U') is not null and
       	object_id('sysmergepublications', 'U') is not null
    begin
        -- This sproc should not be used on a publication that has doesn't have pull subscriptions.
        if @publication = '%'
        begin
            IF NOT EXISTS (select * from sysmergesubscriptions sub, sysmergepublications pub
                where (QUOTENAME(pub.publisher)=@publisher or pub.publisher=@publisher) and pub.publisher_db=@publisher_db and sub.pubid=pub.pubid
                and (sub.subscription_type=1 or sub.subscription_type=2)) -- pull type or anonymous (by default is pull)
            begin
                raiserror(21548, 16, -1)
                return (1)
            end
        end
        else
        begin
            IF NOT EXISTS (select * from sysmergesubscriptions sub, sysmergepublications pub
                where (QUOTENAME(pub.publisher)=@publisher or pub.publisher=@publisher) and pub.publisher_db=@publisher_db  and sub.pubid=pub.pubid
                and pub.name=@publication
                and (sub.subscription_type=1 or sub.subscription_type=2)) -- pull type or anonymous (by default is pull)
            begin
                raiserror(21548, 16, -1)
                return (1)
            end
        end
    end    

    IF object_id('MSsubscription_properties','U') is NULL
    begin
        raiserror(14027, 16, -1, 'The pull subscription properties table ''MSsubscription_properties''')
        return (1)
    end

    -- Expand '%' into individual subscriptions using a cursor
    IF @publication = N'%'
    BEGIN

        BEGIN TRANSACTION subscription_properties_exp
        DECLARE hsubprop CURSOR LOCAL FAST_FORWARD FOR
            SELECT publication 
              FROM MSreplication_subscriptions
             WHERE UPPER(publisher) = UPPER(@publisher)
               AND publisher_db = @publisher_db
               -- NOTE:  publication like '%' is implicit
        IF @@ERROR <> 0
            GOTO ExpFailure
        SELECT @cursor_allocated = 1
    
        OPEN hsubprop
        IF @@ERROR <> 0
            GOTO ExpFailure    
        SELECT @cursor_opened = 1

        FETCH hsubprop INTO @local_publication
        WHILE (@@FETCH_STATUS <> 0)
        BEGIN
                            
            EXEC @retcode = sys.sp_change_subscription_properties
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @local_publication,
                @property = @property,
                @value = @value,
                @publication_type = @publication_type
            IF @retcode <> 0 OR @@ERROR <> 0
                GOTO ExpFailure
            FETCH hsubprop INTO @local_publication
        END

        CLOSE hsubprop
        DEALLOCATE hsubprop
        COMMIT TRANSACTION subscription_properties_exp
        IF @@ERROR <> 0
            GOTO ExpFailure

        RETURN (0)
ExpFailure:

        IF @cursor_opened = 1
            CLOSE hsubprop
        IF @cursor_allocated = 1
            DEALLOCATE hsubprop
        ROLLBACK TRANSACTION subscription_properties_exp
        RETURN (1)
    END    
    ELSE
    BEGIN
        if not exists (select * from MSsubscription_properties 
                   WHERE UPPER(publisher) = UPPER(@publisher)
                   AND publisher_db = @publisher_db
                   AND publication = @publication)
        BEGIN
            RAISERROR(21859, 16, -1, @property)
            RETURN 1
        END
    END

    -- Check for existence of the specified pull subscription
    SELECT @agentid = NULL
    SELECT @job_step_uid = NULL
    SELECT @local_publisher = NULL
    SELECT @dbname = DB_NAME()

    IF @publication_type IN (0,1) OR @publication_type IS NULL
    BEGIN
        IF object_id('MSreplication_subscriptions') is not NULL
        BEGIN
            SELECT @local_publisher = publisher, 
                   @agentid = agent_id
              FROM MSreplication_subscriptions
             WHERE UPPER(publisher) = UPPER(@publisher)
               AND publisher_db = @publisher_db
               AND publication = @publication 

            SELECT @job_step_uid = job_step_uid
                FROM MSsubscription_properties
                WHERE UPPER(publisher) = UPPER(@publisher)
                   AND publisher_db = @publisher_db
                   AND publication = @publication
                   AND publication_type IN (0, 1)
        END
    END

    IF @publication_type = 2 OR (@publication_type IS NULL AND
        @local_publisher IS NULL)
    BEGIN
        IF object_id('dbo.sysmergepublications') is not NULL
        BEGIN
            SELECT @local_publisher = mp.publisher,
                   @agentid = mr.merge_jobid
              FROM dbo.sysmergepublications mp
            INNER JOIN dbo.sysmergesubscriptions ms
                ON mp.pubid = ms.pubid 
               AND UPPER(mp.publisher) = UPPER(@publisher) 
               AND mp.publisher_db = @publisher_db
               AND mp.name = @publication 
               AND ms.db_name = @dbname
               AND UPPER(ms.subscriber_server) = UPPER(@@SERVERNAME)
            INNER JOIN dbo.MSmerge_replinfo mr
                ON ms.subid = mr.repid

            SELECT @job_step_uid = job_step_uid
                FROM MSsubscription_properties
                WHERE UPPER(publisher) = UPPER(@publisher)
                   AND publisher_db = @publisher_db
                   AND publication = @publication
                   AND publication_type = 2
        END
    END 

	-- verify that the logged on user is allowed to make these changes
	SELECT @proxy_id = proxy_id 
		FROM msdb..sysjobsteps 
		WHERE job_id = @agentid
			AND step_uid = @job_step_uid
	IF IS_SRVROLEMEMBER('sysadmin') != 1
		AND @proxy_id IS NULL
	BEGIN
		-- Only members of the sysadmin fixed server role can modify a subscription that does not have a job with a proxy account defined.
		RAISERROR(20813, 16, -1, 'subscription')
		RETURN 1
	END
	
    IF @local_publisher IS NULL
    BEGIN
        RAISERROR(21226, 16, -1, @dbname)
        RETURN (1)
    END

    SELECT @publication_type = publication_type             
      FROM MSsubscription_properties 
     WHERE UPPER(publisher) = UPPER(@publisher)
       AND publisher_db = @publisher_db
       AND publication = @publication

    -- If the subscription does not have a corresponding entry in MSsubscription_properties, 
    -- the subscription is probably created by the ActiveX control. In this case there isn't much
    -- we can do about it so we just return 0.
    IF @publication_type IS NULL
    BEGIN
        RETURN (0)
    END      

	/*
	** Parameter Check: @offloadagent.
	*/
	IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'offload_agent')
	BEGIN
		-- "Parameter 'offload_agent' is no longer supported."
		RAISERROR(21698, 16, -1, 'offload_agent')
		RETURN 1
	END

	IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'offload_server')
	BEGIN
		-- "Parameter 'offload_server' is no longer supported."
		RAISERROR(21698, 16, -1, 'offload_server')
		RETURN 1
	END

	-- Begin changing the properties...
    IF (@property IS NULL)
    begin
        raiserror(14043, 16, -1, '@property', 'sp_change_subscription_properties')
        return (1)
    end
    --
    -- Publisher link information should only be set by sp_link_publication
    --
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'publisher_login') AND (@publication_type = 2)
        select @column_to_update = 'publisher_login'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'publisher_password') AND (@publication_type = 2)
    begin
        select @column_to_update = 'publisher_password'
        EXEC @retcode = sys.sp_MSreplencrypt @value OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1

		update MSsubscription_properties set publisher_password = @value
        	where UPPER(publisher) = UPPER(@publisher)
                and publisher_db = @publisher_db
                and publication = @publication
        if @@error <> 0 
            goto Failure

		return 0
    end
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'publisher_security_mode') AND (@publication_type = 2)
        select @column_to_update = 'publisher_security_mode'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distributor')
        select @column_to_update = 'distributor'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distributor_login')
        select @column_to_update = 'distributor_login'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distributor_password')
    begin
        select @column_to_update = 'distributor_password'
        EXEC @retcode = sys.sp_MSreplencrypt @value OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1

        update MSsubscription_properties set distributor_password = @value
        	where UPPER(publisher) = UPPER(@publisher)
                and publisher_db = @publisher_db
                and publication = @publication
        if @@error <> 0 
            goto Failure

        return 0
    end
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distributor_security_mode')
        select @column_to_update = 'distributor_security_mode'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'ftp_address')
        select @column_to_update = 'ftp_address'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'ftp_port')
        select @column_to_update = 'ftp_port'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'ftp_login')
        select @column_to_update = 'ftp_login'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'ftp_password')
        select @column_to_update = 'ftp_password'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'alt_snapshot_folder')
    BEGIN
        select @column_to_update = 'alt_snapshot_folder'
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'working_directory')
    BEGIN
        select @column_to_update = 'working_directory'
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_ftp')
        select @column_to_update = 'use_ftp'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'dts_package_name')
        select @column_to_update = 'dts_package_name'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'dts_package_password')
    begin
    	IF RTRIM(ISNULL(@value, N'')) = N''
    	BEGIN
    		-- Use of DTS packages in replication requires a non-NULL/non-empty string password. Specify a valid value for parameter '%s'.
			RAISERROR(21732,16, -1, '@value')
			RETURN 1
    	END
    	
        select @column_to_update = 'dts_package_password'
        EXEC @retcode = sys.sp_MSreplencrypt @value OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1

        update MSsubscription_properties set dts_package_password = @value
        	where UPPER(publisher) = UPPER(@publisher)
                and publisher_db = @publisher_db
                and publication = @publication
        if @@error <> 0 
            goto Failure

        return 0
    end
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'dts_package_location')
        select @column_to_update = 'dts_package_location'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = N'dynamic_snapshot_location') and @publication_type = 2
    BEGIN
        select @column_to_update = N'dynamic_snapshot_location'
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'hostname')
        select @column_to_update = 'hostname'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'internet_login')
        select @column_to_update = 'internet_login'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_web_sync')
        select @column_to_update = 'use_web_sync'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'internet_url')
        select @column_to_update = 'internet_url'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'internet_password')
    begin
        select @column_to_update = 'internet_password'
        EXEC @retcode = sys.sp_MSreplencrypt @value OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1

        update MSsubscription_properties set internet_password = @value
        	where UPPER(publisher) = UPPER(@publisher)
                and publisher_db = @publisher_db
                and publication = @publication
        if @@error <> 0 
            goto Failure

        return 0
    end
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'internet_security_mode')
        select @column_to_update = 'internet_security_mode'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'internet_timeout')
        select @column_to_update = 'internet_timeout'
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distrib_job_login')
    BEGIN
        -- Cloud Lifter edition (CL) uses value provided for distrib_job_login
        -- for SQL authentication (Windows authentication and proxies are not supported in CL)
        IF sys.fn_MSrepl_editionid() = 32
        BEGIN
	        select @column_to_update = 'job_login'
            update MSsubscription_properties set job_login = @value
                where UPPER(publisher) = UPPER(@publisher)
                    and publisher_db = @publisher_db
                    and publication = @publication
                if @@error <> 0
                    goto Failure
        END
        ELSE
        BEGIN
            IF sys.fn_replisvalidwindowsloginformat(@value) != 1
            BEGIN
                -- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_change_subscription_properties'.
                RAISERROR(21797, 16, -1, '@value (distrib_job_login)', 'sp_change_subscription_properties')
                RETURN 1
            END
            
            -- update the Proxy Account login
            exec @retcode = sys.sp_MSchange_repl_job @id = @agentid,
                                                    @step_uid = @job_step_uid,
                                                    @login = @value
            if @@error != 0 or @retcode != 0
                return 1
        END

        return 0
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distrib_job_password')
    BEGIN
        -- Cloud Lifter edition (CL) uses value provided for distrib_job_password
        -- for SQL authentication (Windows authentication and proxies are not supported in CL)
        IF sys.fn_MSrepl_editionid() = 32
        BEGIN
            select @column_to_update = 'job_password'
            EXEC @retcode = sys.sp_MSreplencrypt @value OUTPUT
            IF @@error <> 0 OR @retcode <> 0
                return 1

            update MSsubscription_properties set job_password = @value
                where UPPER(publisher) = UPPER(@publisher)
                    and publisher_db = @publisher_db
                    and publication = @publication
            if @@error <> 0 
                goto Failure
        END
        ELSE
        BEGIN
            -- update the Proxy Account password
            exec @retcode = sys.sp_MSchange_repl_job @id = @agentid,
                                                    @step_uid = @job_step_uid,
                                                    @password = @value
            if @@error != 0 or @retcode != 0
                return 1
        END

        return 0
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'merge_job_login')
    BEGIN
    	IF sys.fn_replisvalidwindowsloginformat(@value) != 1
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_change_subscription_properties or sp_changemergepullsubscription'.
			RAISERROR(21797, 16, -1, '@value (merge_job_login)', 'sp_change_subscription_properties or sp_changemergepullsubscription')
			RETURN 1
		END
		
        -- update the Proxy Account login
        exec @retcode = sys.sp_MSchange_repl_job @id = @agentid,
        										@step_uid = @job_step_uid,
                                                @login = @value
        if @@error != 0 or @retcode != 0
            return 1

        return 0
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'merge_job_password')
    BEGIN
        -- update the Proxy Account password
        exec @retcode = sys.sp_MSchange_repl_job @id = @agentid,
        										@step_uid = @job_step_uid,
                                                @password = @value
        if @@error != 0 or @retcode != 0
            return 1

        return 0
    END
	ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'memory_optimized')
    BEGIN
        -- retrieve distributor rpc info
		EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT, 
    										@distribdb = @distribution_db OUTPUT,
    										@publisher = @publisher
		
		IF @@ERROR <> 0 or @retcode <> 0 or @distributor is NULL
		BEGIN
			-- "The Distributor has not been installed correctly."
			RAISERROR (20036, 16, -1)
			RETURN 1
		END
		
		SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSchange_distribution_agent_properties'	
		SELECT @subscriber = @@SERVERNAME
		SELECT @subscriber_db = DB_NAME()
		EXEC @retcode = @distproc @publisher		= @publisher,
									@publisher_db	= @publisher_db,
									@publication 	= @publication,
									@subscriber 	= @subscriber,
									@subscriber_db	= @subscriber_db,
									@property		= @property,
									@value			= @value
		IF @@ERROR <> 0 or @retcode <> 0
		BEGIN
			goto Failure
		END
    END
    ELSE
    BEGIN
        raiserror (3217, 16, -1, '@property')
        return(1)
    END

    IF @column_to_update in ('use_ftp', 'use_web_sync')
    BEGIN
        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N'true'
        BEGIN
            SELECT @value_bit = 1
        END
        ELSE IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N'false'
        BEGIN
            SELECT @value_bit = 0
        END
        ELSE
        BEGIN 
            RAISERROR(14137, 16, -1)
        END
    END

    IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'publisher_security_mode') AND (@publication_type = 2)
    BEGIN
        IF @value not in (0,1,2) 
        BEGIN
            raiserror(3217, 16, -1, '@value')
            return(1)
        END
        select @value_string = convert(nvarchar(1), @value)
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) in ('distributor_security_mode', 'internet_security_mode'))
    BEGIN
        IF @value not in (0,1) 
        BEGIN
            raiserror(3217, 16, -1, '@value')
            return(1)
        END
        select @value_string = convert(nvarchar(1), @value)
    END
    ELSE IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'dts_package_location')
    BEGIN
        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N'distributor' 
            select @value_string = '0'
        ELSE IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N'subscriber' 
            select @value_string = '1'
        ELSE 
        begin
            raiserror(20587, 16, -1, 'dts_package_location', 'sp_change_subscription_properties')
            return(1)
        end

    END
    ELSE
    BEGIN
        IF @value IS NULL
        BEGIN
            select @value_string = 'null'
        END
        ELSE
        BEGIN
			select @value_string = 'N''' + replace(rtrim(@value),'''', '''''') + ''''
        END
    END    

    -- Ignore ftp_address, ftp_port, ftp_login, ftp_password on post 7.0 servers
    IF (@column_to_update IN (N'ftp_address', N'ftp_port', N'ftp_login', N'ftp_password'))
    BEGIN
        RETURN (0)
    END

    BEGIN TRANSACTION subscription_properties
    IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_ftp')
    begin
        update MSsubscription_properties set use_ftp = @value_bit where 
            UPPER(publisher) = UPPER(@publisher) and 
            publisher_db = @publisher_db and
            publication = @publication 
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = N'dynamic_snapshot_location'
    begin
        select @value = rtrim(ltrim(@value))

        update MSsubscription_properties 
           set dynamic_snapshot_location = @value
         where upper(publisher) = upper(@publisher) 
           and publisher_db = @publisher_db 
           and publication = @publication
        if @@error <> 0 or @retcode <> 0
            goto Failure

        -- Call helper functions to add/update or remove the -DynamicSnapshotLocationParameter
        if @value is null or @value = N''
        begin
            update msdb.dbo.sysjobsteps 
               set command = sys.fn_removeparameterwithargument(command, N'DynamicSnapshotLocation') collate database_default
             where job_id = @agentid
               and lower(subsystem collate SQL_Latin1_General_CP1_CS_AS) = N'merge'
        end
        else
        begin

            select @commandline = command 
              from msdb.dbo.sysjobsteps
             where job_id = @agentid
               and lower(subsystem collate SQL_Latin1_General_CP1_CS_AS) = N'merge'

            select @commandline = sys.fn_updateparameterwithargument(@commandline, N'DynamicSnapshotLocation', sys.fn_replquotename(@value, default)) collate database_default

            -- Need to remove existing alternate snapshot folder parameters
            -- and file transfer type parameters

            select @commandline = sys.fn_removeparameterwithargument(@commandline, N'FileTransferType') collate database_default
            
            select @commandline = sys.fn_removeparameterwithargument(@commandline, N'AltSnapshotFolder') collate database_default

            update msdb.dbo.sysjobsteps
               set command = @commandline
             where job_id = @agentid
               and lower(subsystem collate SQL_Latin1_General_CP1_CS_AS) = N'merge' 

        end
    end
    else IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_web_sync')
    begin
        update MSsubscription_properties set use_web_sync = @value_bit where 
            UPPER(publisher) = UPPER(@publisher) and 
            publisher_db = @publisher_db and
            publication = @publication 
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure
    end
    else IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'distributor_security_mode')
    begin
        -- Security Mode 1
        IF @value = 1
        BEGIN
            SELECT @password = newid()

            -- Encrypt the password before storing
            EXEC @retcode = sys.sp_MSreplencrypt @password OUTPUT
            IF @@ERROR <> 0 OR  @retcode <> 0
                RETURN 1

            update MSsubscription_properties 
                set distributor_security_mode = 1,
                    distributor_login = N'',
                    distributor_password = @password
            where UPPER(publisher) = UPPER(@publisher) 
                and publisher_db = @publisher_db 
                and publication = @publication 
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
        -- Security Mode 0
        ELSE
        BEGIN    
            update MSsubscription_properties 
                set distributor_security_mode = 0
            where UPPER(publisher) = UPPER(@publisher) 
                and publisher_db = @publisher_db 
                and publication = @publication 
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
    end
    else IF (lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'publisher_security_mode') AND (@publication_type = 2)
    begin
        -- Security Mode 1
        IF @value = 1
        BEGIN
            SELECT @password = newid()

            -- Encrypt the password before storing
            EXEC @retcode = sys.sp_MSreplencrypt @password OUTPUT
            IF @@ERROR <> 0 OR  @retcode <> 0
                RETURN 1

            update MSsubscription_properties 
                set publisher_security_mode = 1,
                    publisher_login = N'',
                    publisher_password = @password
            where UPPER(publisher) = UPPER(@publisher) 
                and publisher_db = @publisher_db 
                and publication = @publication 
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
        -- Security Mode 0
        ELSE
        BEGIN    
            update MSsubscription_properties 
                set publisher_security_mode = 0
            where UPPER(publisher) = UPPER(@publisher) 
                and publisher_db = @publisher_db 
                and publication = @publication 
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
    end
    else    
    begin
        -- Password is encrypted. Must prefix every string with N' 
        -- otherwise, the chars will be convert to '???'
        select @command = N'update MSsubscription_properties set ' + @column_to_update + '= ' + @value_string
                + ' where UPPER(publisher) = UPPER(' + quotename(@publisher,'''') 
                + ') and publisher_db = ' + quotename(@publisher_db, '''')
                + ' and publication = ' + quotename(@publication,'''')
       	
        EXEC (@command)
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure
    end

    IF (@publication_type = 0 or @publication_type = 1) AND @publication <> N'%' AND
        @column_to_update IN ('distributor',
                              'distributor_login',
                              'distributor_password',
                              'distributor_security_mode',
                              'ftp_address',
                              'ftp_port',
                              'ftp_login',
                              'ftp_password',
                              'alt_snapshot_folder',
                              'working_dir',
                              'use_ftp')
    BEGIN
        SELECT @subscription_type = subscription_type
          FROM MSreplication_subscriptions
         WHERE UPPER(publisher) = UPPER(@publisher)
           AND publisher_db = @publisher_db
           AND publication = @publication
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        -- Update the property for all shared subscriptions
        IF @column_to_update IN ('distributor_security_mode', 
                                 'ftp_port')
        BEGIN
            SELECT @intvalue = CONVERT(int, @value)
            EXEC @retcode = sys.sp_MSupdatesharedagentproperties 
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @property = @column_to_update,
                    @intvalue = @intvalue,
                    @subscription_type = @subscription_type
        END
        ELSE IF @column_to_update IN ('use_ftp')
        BEGIN
            EXEC @retcode = sys.sp_MSupdatesharedagentproperties 
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @property = @column_to_update,
                    @intvalue = @value_bit,
                    @subscription_type = @subscription_type
        END
        ELSE 
        BEGIN
            EXEC @retcode = sys.sp_MSupdatesharedagentproperties 
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @property = @column_to_update,
                    @strvalue = @value,
                    @subscription_type = @subscription_type
        END  
    
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure
    END

    -- Ftp and alternate snapshot folder are mutually 
    -- exclusive options but instead of raising an error
    -- when both of them are non-null, nullify the other 
    -- property when either one of them is set to non-null
    -- value since properties can only be set one at a time

    -- 'dynamic_snapshot_location' should also be added to the
    -- list of mutually exclusive properties


    IF (@column_to_update = 'ftp_address') AND (@value <> N''
       AND @value IS NOT NULL)
    BEGIN
        EXEC @retcode = sys.sp_change_subscription_properties 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'alt_snapshot_folder',
                @value = NULL

        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure
    END

    IF (@column_to_update = 'use_ftp') AND (@value_bit = 1)
    BEGIN
        EXEC @retcode = sys.sp_change_subscription_properties 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'alt_snapshot_folder',
                @value = NULL

        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        IF @publication_type = 2
        BEGIN
            EXEC @retcode = sys.sp_change_subscription_properties
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @property = 'dynamic_snapshot_location',
                    @value = NULL
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
    END

    IF (@column_to_update = 'alt_snapshot_folder') AND (@value <> N''
       AND @value IS NOT NULL)
    BEGIN
        EXEC @retcode = sys.sp_change_subscription_properties 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'ftp_address',
                @value = NULL

        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        EXEC @retcode = sys.sp_change_subscription_properties 
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'use_ftp',
                @value = 'false'

        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        IF @publication_type = 2
        BEGIN
            EXEC @retcode = sys.sp_change_subscription_properties
                    @publisher = @publisher,
                    @publisher_db = @publisher_db,
                    @publication = @publication,
                    @property = 'dynamic_snapshot_location',
                    @value = NULL
            IF @@error <> 0 OR @retcode <> 0
                GOTO Failure
        END
    END


    IF (@column_to_update = 'dynamic_snapshot_location') AND (@value <> N''
        AND @value IS NOT NULL)
    BEGIN

        EXEC @retcode = sys.sp_change_subscription_properties
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'ftp_address',
                @value = NULL
            
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        EXEC @retcode = sys.sp_change_subscription_properties
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'use_ftp',
                @value = 'false'
            
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

        EXEC @retcode = sys.sp_change_subscription_properties
                @publisher = @publisher,
                @publisher_db = @publisher_db,
                @publication = @publication,
                @property = 'alt_snapshot_folder',
                @value = NULL
            
        IF @@error <> 0 OR @retcode <> 0
            GOTO Failure

    END

    IF @@error <> 0 OR @retcode <> 0
        GOTO Failure

    COMMIT TRANSACTION subscription_properties
    RETURN (0)
            
Failure:        
    ROLLBACK TRANSACTION subscription_properties
    RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_change_subscription_properties] TO [public] AS [dbo]
GO
