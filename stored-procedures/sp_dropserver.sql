SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropserver]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropserver] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropserver]
	@server [sysname],
	@droplogins [char](10)
WITH EXECUTE AS CALLER
AS
declare @ret int, @is_linked bit, @server_id int
	select @droplogins = LOWER(@droplogins collate Latin1_General_CI_AS)

	-- DISALLOW USER TRANSACTION
	set implicit_transactions off
	if @@trancount > 0
	begin
		raiserror(15002,-1,-1,'sys.sp_dropserver')
		return (1)
	end

	-- CHECK PERMISSIONS
	if not (has_perms_by_name(null, null, 'alter any linked server') = 1)
	begin
		EXEC %%System().AuditEvent(ID = 1380209484, Success = 0, TargetLoginName = NULL, TargetUserName = NULL, Role = NULL, Object = NULL, Provider = NULL, Server = @server)
		raiserror(15247,-1,-1)
		return (1)
	end
	else
	begin
		EXEC %%System().AuditEvent(ID = 1380209484, Success = 1, TargetLoginName = NULL, TargetUserName = NULL, Role = NULL, Object = NULL, Provider = NULL, Server = @server)
	end

	-- VALIDATE OPTION
	if @droplogins is not null AND @droplogins <> 'droplogins'
	begin
		raiserror(15600,-1,-1, 'sys.sp_dropserver')
		return (1)
	end

	begin transaction

	-- CHECK/LOCK SERVER NAME / GET SERVER ID
	EXEC %%LinkedServer ( Name = @server ) . Lock ( Exclusive = 1 )
	IF @@ERROR <> 0
	begin
		rollback tran
		raiserror(15015,-1,-1,@server)
		return (1)
	end

	-- CHECK @droplogins PARAMETER: No sysremotelogins OR sysoledbusers ROWS EXCEPT
	--	THE DEFAULT OLEDB-MAPPING.
	if @droplogins is null AND exists (
		SELECT * FROM master.dbo.sysservers s WHERE s.srvname = @server AND
			(	exists (select * from master.dbo.sysremotelogins WHERE remoteserverid = s.srvid)
			OR	exists (select * from master.dbo.sysoledbusers WHERE rmtsrvid = s.srvid
						AND NOT (loginsid IS NULL AND status = 1) )
		)	)
	begin
		rollback tran
		raiserror(15190,-1,-1,@server)
		return (1)
	end

	-- CHECK TO SEE IF THE SERVER IS USED BY REPLICATION.
	if object_id('sp_MSrepl_check_server') is not null
	begin
		EXEC @ret = sp_MSrepl_check_server @server
		if @ret <> 0 or @@error <> 0
		begin
			rollback tran
			return 1
		end
	end
	
	-- is this a linked server?
	select @is_linked = is_linked, @server_id = server_id from sys.servers where name = @server

	-- do not allow dropping local instance on Cloud Lifter.
	if @@SERVERNAME = @server and @is_linked = 0 and serverproperty('EngineEdition') = 8 
	begin
		rollback tran
		raiserror(41917, 16, 1)
		return (1)
	end

	-- DROP THE SERVER (ALSO DROPS ALL REMOTE/LINKED LOGINS)
	EXEC %%LinkedServer ( Name = @server ) . Remove()

	-- Server_id = 0 means the local server name
	if @server_id = 0
	begin
		-- EMDEventType(x_eet_Alter_Instance), EMDUniversalClass(x_eunc_Server), src major id, src minor id, src name
		-- -1 means ignore target stuff, target major id, target minor id, target name,
		-- # of parameters, 5 parameters
		EXEC %%System().FireTrigger(ID = 214, ID = 100, ID = 0, ID = 0, Value = NULL,
			ID = -1, ID = 0, ID = 0, Value = NULL, 
			ID = 2, Value = @server, Value = @droplogins, Value = NULL, Value = NULL, Value = NULL, Value = NULL, Value = NULL)
	end
	else if @is_linked = 1
	begin
		-- EMDEventType(x_eet_Drop_LinkedServer), EMDUniversalClass(x_eunc_LinkedServer), src major id, src minor id, src name
		-- -1 means ignore target stuff, target major id, target minor id, target name,
		-- # of parameters, 5 parameters
		EXEC %%System().FireTrigger(ID = 262, ID = 102, ID = 0, ID = 0, Value = @server,
			ID = -1, ID = 0, ID = 0, Value = NULL, 
			ID = 2, Value = @server, Value = @droplogins, Value = NULL, Value = NULL, Value = NULL, Value = NULL, Value = NULL)
	end
	else
	begin
		-- EMDEventType(x_eet_Drop_Remote_Server), EMDUniversalClass(x_eunc_Server), src major id, src minor id, src name
		-- -1 means ignore target stuff, target major id, target minor id, target name,
		-- # of parameters, 5 parameters
		EXEC %%System().FireTrigger(ID = 240, ID = 100, ID = 0, ID = 0, Value = @server,
			ID = -1, ID = 0, ID = 0, Value = NULL, 
			ID = 2, Value = @server, Value = @droplogins, Value = NULL, Value = NULL, Value = NULL, Value = NULL, Value = NULL)
	end
	-- SUCCESS
	commit transaction
	return (0) -- sp_dropserver
GO
GRANT EXECUTE ON [sys].[sp_dropserver] TO [public] AS [dbo]
GO
