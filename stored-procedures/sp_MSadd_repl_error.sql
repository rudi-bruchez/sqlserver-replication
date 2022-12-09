SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_repl_error]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_repl_error] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_repl_error]
	@id [int],
	@error_type_id [int],
	@source_type_id [int],
	@source_name [sysname],
	@error_code [sysname],
	@error_text [nvarchar](max),
	@session_id [int],
	@add_event_log [int],
	@event_log_context [nvarchar](max),
	@map_source_type [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	declare @xact_seqno varbinary(16)
	declare @command_id int
	declare @binctx binary(128)
	declare @event_log_text nvarchar(4000)

	-- these values can be found in SQLREPL.h
	declare @REPL_SOURCE_NULL 		int,
			@REPL_SOURCE_COMMAND 	int,
			@REPL_SOURCE_AGENT 		int,
			@REPL_SOURCE_OS 		int,
			@REPL_SOURCE_ODBC 		int,
			@REPL_SOURCE_SQLSERVER 	int,
			@REPL_SOURCE_NETLIB 	int,
			@REPL_SOURCE_SQLDMO 	int,
			@REPL_MERGE_PROVIDER 	int,
			@REPL_MERGE_PROCESS 	int,
			@REPL_SOURCE_TRANSPORT	int,
			@REPL_SOURCE_SQLCE 		int,
			@REPL_SOURCE_OCI 		int,
			@REPL_SOURCE_OLEDB 		int,
			@REPL_SOURCE_SMO 		int,
			@REPL_SOURCE_RMO 		int,
			@REPL_SOURCE_ORACLE	int,
			@REPL_SOURCE_DB2	int

	select @REPL_SOURCE_NULL		= 0,
			@REPL_SOURCE_COMMAND	= 1,
			@REPL_SOURCE_AGENT		= 2,
			@REPL_SOURCE_OS			= 3,
			@REPL_SOURCE_ODBC		= 4,
			@REPL_SOURCE_SQLSERVER	= 5,
			@REPL_SOURCE_NETLIB		= 6,
			@REPL_SOURCE_SQLDMO		= 7,
			@REPL_MERGE_PROVIDER	= 8,
			@REPL_MERGE_PROCESS		= 9,
			@REPL_SOURCE_TRANSPORT	= 10,
			@REPL_SOURCE_SQLCE      = 11,
			@REPL_SOURCE_OCI 		= 12,
			@REPL_SOURCE_OLEDB		= 13,
			@REPL_SOURCE_SMO		= 14,			
			@REPL_SOURCE_RMO		= 15,			
			@REPL_SOURCE_ORACLE		= 16,			
			@REPL_SOURCE_DB2		= 17

	-- Security Check
	-- require the login to be in cache regardless of the publication id and agent_id.
	-- This means that once a agent get into the distribution db, it
	-- can add any error.   
	exec @retcode = sys.sp_MScheck_pull_access
	if @@error <> 0 or @retcode <> 0
		return (1)
		
	if object_id('MSrepl_errors') is NULL
		return 0

	if @map_source_type = 1
	begin
		-- Here we will override the source_name if we know we sould.
		-- The only case we shouldn't is when the user input for source
		-- type id is set to NULL or REPL_SOURCE_VALID. We force the 
		-- change of source name to allow the UI to construct help links.
		select @source_type_id = ISNULL(@source_type_id, @REPL_SOURCE_NULL)
		
		if @source_type_id in (@REPL_SOURCE_AGENT,
								@REPL_SOURCE_OS, 
								@REPL_MERGE_PROVIDER, 
								@REPL_MERGE_PROCESS,
								@REPL_SOURCE_TRANSPORT)
		begin
			select @source_name = N'MSSQL_REPL'
		end
		else if @source_type_id  in ( @REPL_SOURCE_ORACLE,
								@REPL_SOURCE_OCI)
		begin
			select @source_name = N'MSSQL_REPL_ORACLE'
		end
		else if @source_type_id  = @REPL_SOURCE_DB2
		begin
			select @source_name = N'MSSQL_REPL_DB2'
		end
		else
		begin
			select @source_name = N'MSSQL_ENG'
		end
	end
	
	select @xact_seqno = xact_seqno, @command_id = command_id from dbo.MSrepl_errors where
		id = @id and xact_seqno is not null

	if @session_id is null
	begin
		select @binctx = isnull(context_info(),0x00)
		set @session_id = cast( @binctx AS int )
	end

	-- Insert into the Event log
--       if (@add_event_log = 1) and (is_member('db_owner') = 1)
--       begin
--       	if @event_log_context is not null
--       		select @event_log_text = @event_log_context + @error_text
--    	else
--       		select @event_log_text = @error_text
--		select @event_log_text = @source_name + ' -(' + @error_code + ') ' + @event_log_text
--           	exec master.dbo.xp_logevent  70000, @event_log_text, 'ERROR'
--       end
			
	INSERT INTO dbo.MSrepl_errors (id, time, error_type_id, source_type_id, source_name,
				error_code, error_text, xact_seqno, command_id, session_id)
		VALUES (@id, getdate(), @error_type_id, @source_type_id,
				@source_name, @error_code, @error_text, @xact_seqno, @command_id, @session_id)
	IF @@ERROR <> 0
	BEGIN
	   RETURN (1)
	END
	
	-- delete the placeholder row since it is never needed by anyone.
	delete from dbo.MSrepl_errors where id = @id and error_type_id is null
	
	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_repl_error] TO [public] AS [dbo]
GO
