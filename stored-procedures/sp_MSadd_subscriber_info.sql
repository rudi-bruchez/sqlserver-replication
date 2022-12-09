SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_subscriber_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_subscriber_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_subscriber_info]
	@publisher [sysname],
	@subscriber [sysname],
	@type [tinyint],
	@login [sysname],
	@password [nvarchar](524),
	@commit_batch_size [int],
	@status_batch_size [int],
	@flush_frequency [int],
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
	@retryattempts [int],
	@retrydelay [int],
	@description [nvarchar](255),
	@security_mode [int],
	@encrypted_password [bit],
	@internal [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on

	declare @retcode int
	declare @oledbprovider nvarchar(256)
	declare @platform_nt binary
	declare @original_type int
	declare @message nvarchar(1000)

	select @platform_nt = 0x1

	-- Get subscriber port number
	declare @subscriber_with_port sysname
	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT,
		@srvname_with_port = @subscriber_with_port OUTPUT

	-- Security Check
	IF IS_SRVROLEMEMBER ('sysadmin') != 1
	BEGIN
		-- "You do not have sufficient permission to run this command."
		RAISERROR(14260, 16, -1)
		RETURN 1
	END
	
 	IF (UPPER(@subscriber) = UPPER(@@SERVERNAME) and ( @platform_nt != platform() & @platform_nt ) and @security_mode = 1)
	BEGIN
		RAISERROR(21038, 16, -1)
		RETURN (1)
	END

	-- Check to ensure a login is provided if security mode is SQL Server authentication.
	select @login = rtrim(ltrim(isnull(@login, '')))

	-- Security Mode = 1
	if @security_mode = 1
	begin
		select @login = N'',
				@password = newid()
	end
	-- Security Mode = 0
	else if @login = ''
	begin
		-- '@login cannot be null or empty when @security_mode is set to 0 (SQL Server authentication).'
		raiserror(21694, 16, -1, '@login', '@security_mode')
		return 1
	end

	-- Verify subscriber is not a HREPL publisher.
	-- Only allow if publisher is not HREPL
	IF EXISTS
	(
		SELECT	srvname
		FROM	master.dbo.sysservers ss LEFT OUTER JOIN msdb.dbo.MSdistpublishers msdp
		  ON	ss.srvname = msdp.name
		WHERE	UPPER(ss.srvname) = UPPER(@subscriber) collate database_default
		  AND	ss.pub = 1
		  AND	msdp.publisher_type != N'MSSQLSERVER'
	)
	BEGIN
		RAISERROR (21677, 16, -1, @subscriber)
		RETURN(1)
	END
	
	/* Add the subscriber to dbo.sysservers as a RPC server, if it does not
	** already exist.sp_MSadd_subserver does the check.
	*/
		declare @subscriber_provstr	 nvarchar(4000) 
		set @subscriber_provstr = sys.fn_getproviderstring(@subscriber_with_port)

		exec @retcode = sys.sp_MSadd_subserver @subscriber = @subscriber,
											@type = @type,
											@subscriber_provstr = @subscriber_provstr

		if @@error <> 0 OR @retcode <> 0
			return 1

	/* Add the subscriber to MSreplservers , if it does not already exist.
	*/   
	if not exists (select * from MSreplservers where  UPPER(srvname collate database_default) = UPPER(@subscriber collate database_default))
	begin
		begin tran
		DECLARE @srvid smallint
		select @srvid = isnull(max(srvid),0)+1 from MSreplservers with (holdlock)
	    insert into MSreplservers
		(srvid, srvname) 
	    select @srvid, srvname from master.dbo.sysservers where  UPPER(srvname collate database_default) = UPPER(@subscriber collate database_default)
		commit tran 
	end

    -- Encrypt the password
    -- We no longer supported passing in encrypted passwords
	IF @encrypted_password = 1
	BEGIN
		-- Parameter '@encrypted_password' is no longer supported.
		RAISERROR(21698, 16, -1, '@encrypted_password')
		RETURN (1)
	END

	if (@type = 3)
	begin
		select @oledbprovider = providername from master.dbo.sysservers where UPPER(srvname) = UPPER(@subscriber)
		if (@oledbprovider = 'sqloledb')
			select @security_mode = 1
		else
			select @security_mode = 0
	end

	-- retrieve the stored type if a subscriber entry exists so 
	-- that we can verify if we need to do any extra processing
	-- basically we never want to add the entry if it already exists
	SELECT @original_type = type
		FROM MSsubscriber_info
		WHERE UPPER(subscriber) = UPPER(@subscriber)
			AND UPPER(publisher) = UPPER(@publisher)
	IF @original_type IS NOT NULL
	BEGIN
		-- if the types match or we are an internal
		-- call then do not fail, just exit w/o err
		IF @original_type = @type
			OR @internal = N'YUKON'
		BEGIN
			RETURN 0
		END

		SELECT @message = @subscriber + ''', type = ''' + CAST(@original_type as nvarchar)
		
		-- The server '@server', type = '1' already exists.
		RAISERROR(15028, 16, -1, @message)
		RETURN 1
	END

   EXEC @retcode = sys.sp_MSreplencrypt @password OUTPUT
   IF @@error <> 0 OR @retcode <> 0
	   return 1

   begin tran
   save TRAN addsub_info
		
   insert MSsubscriber_info (publisher, subscriber, type, login, password, description, security_mode)
		 values (@publisher, @subscriber, @type, @login, @password, @description, @security_mode)
	if @@error <> 0
	goto UNDO

	/*
	** Schedule information is added for backward compartibility reason, agent_type = 0
	*/
   insert MSsubscriber_schedule values(@publisher, @subscriber, 0, @frequency_type,
										@frequency_interval,
										@frequency_relative_interval,
										@frequency_recurrence_factor ,
										@frequency_subday ,
										@frequency_subday_interval,
										@active_start_time_of_day,
										@active_end_time_of_day ,
										@active_start_date ,
										@active_end_date )
	if @@error <> 0
	goto UNDO
	COMMIT TRAN

	Return (0)
UNDO:
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRAN addsub_info
		COMMIT TRAN
	end
	return (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_subscriber_info] TO [public] AS [dbo]
GO
