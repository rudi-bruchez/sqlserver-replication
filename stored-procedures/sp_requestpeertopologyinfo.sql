SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_requestpeertopologyinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_requestpeertopologyinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_requestpeertopologyinfo]
	@publication [sysname],
	@request_id [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @OPT_ENABLED_FOR_P2P int
	
	declare @retcode		int,
			@cmd			nvarchar(4000),
			@originator		sysname,
			@originator_db	sysname

	select @OPT_ENABLED_FOR_P2P = 0x1
	
	select @cmd = NULL,	
			@request_id = NULL,
			@originator = publishingservername(),
			@originator_db = db_name()

	-- Security Check
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
	end

	-- this procedure can not be executed in a user
	-- transaction because it needs to be in its own tran
	-- space (it can not be mixed with replicated cmds).
	--
	-- we use this tmp table insert to force any implicit
	-- transaction (user may set IMPLICIT_TRANSACTIONs on)
	declare @check_tran table(col1 int)
	insert into @check_tran(col1) values (1)
	
	if @@trancount > 0
	begin
		-- The procedure 'sp_requestpeerresponse' cannot be executed within a transaction.
		raiserror(15002, 16, -1, 'sp_requestpeertopologyinfo')
		return 1
	end
	
	-- check this db is published
	if sys.fn_MSrepl_istranpublished(db_name(),0) <> 1
    begin
		-- The database is not published.
		raiserror (18757, 16, -1)
		return 1
	end
	
	-- check publication name
	if @publication is null
    begin
		-- The parameter @publication cannot be NULL.
        raiserror (14043, 16, -1, @publication, 'sp_requestpeertopologyinfo')
        return 1
    end

	-- validate publication setting
	if not exists(select * 
					from syspublications
					where (options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
						and name = @publication)	
	begin
		-- The Peer-To-Peer publication ''%s'' does not exist.
		raiserror (20808, 16, -1, @publication)
		return 1
	end

	begin transaction tr_sp_requestpeertopologyinfo
	save transaction tr_sp_requestpeertopologyinfo

	insert into MSpeer_topologyrequest
		(
			publication
		) 
		values
		(
			@publication
		)
	if @@error <> 0 
	begin
		-- The procedure sys.sp_requestpeertopolgyinfo failed to INSERT into the resource MSpeer_topologyrequest. Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_requestpeertopolgyinfo', 'INSERT into', 'MSpeer_request.', @@error)
		goto FAILURE
	end

	select @request_id = scope_identity()

	insert into MSpeer_topologyresponse
		(
			request_id,
			peer,
			peer_version,
			peer_db
		)
		select distinct @request_id,
				UPPER(originator),
				originator_version,
				originator_db
			from MSpeer_lsns
			where
				originator_publication = @publication
	if @@error <> 0
	begin
		-- The procedure sys.MSpeer_topologyrequest failed to INSERT into the resource MSpeer_topologyresponse Server error =  0.
		raiserror (21499, 16, -1, 'sys.MSpeer_topologyrequest', 'INSERT into', 'MSpeer_topologyresponse.', @@error)
		goto FAILURE
	end

	--send logic to handle older servers with the command
	select @cmd = N'if object_id(N''sys.sp_MSpeersendtopologyinfo'', ''P'') is not null begin '+
					N'exec sys.sp_MSpeersendtopologyinfo @request_id=' + cast(@request_id as nvarchar) + 
												N',@originator=N' + quotename(@originator, '''') + 
												N',@originator_db=N' + quotename(@originator_db, '''') +
												N',@originator_publication=N' + quotename(@publication, '''') +
				--if the server is old, send the apply command back with no connection info
				N' end else begin declare @cmd nvarchar(max) select @cmd = N'''+
					N'if object_id(N''''sys.sp_MSpeerapplytopologyinfo'''', ''''P'''') is not null ' + 
					N'begin ' +
					    N'exec sys.sp_MSpeerapplytopologyinfo @request_id=' + cast(@request_id as nvarchar) +
												N',@originator=N''' + quotename(@originator, '''') + N'''' +
												N',@originator_db=N''' + quotename(@originator_db, '''') + N'''' +
												N',@response_srvr=N''+quotename(publishingservername(), '''''''')+N''' +
												N',@response_db=N''+quotename(db_name(), '''''''') + N''' + 
												N',@response_srvr_version= @@microsoftversion ' +
												N',@response_originator_id = NULL ' +
												N',@response_conflict_retention = NULL ' +
					N'end' +
				       N''' exec sys.sp_MSpeertopeerfwdingexec @command = @cmd, @publication = N'+quotename(@publication, '''')+N', @execute = 0 end'
				
	exec @retcode = sys.sp_MSpeertopeerfwdingexec @command = @cmd,
													@publication = @publication,
													@execute = 1,
													@change_results_originator = 1
	if @@error <> 0 or @retcode <> 0
		goto FAILURE

	commit transaction tr_sp_requestpeertopologyinfo

	return 0
FAILURE:
	rollback transaction tr_sp_requestpeertopologyinfo
	commit transaction

	return 1
	
end
GO
GRANT EXECUTE ON [sys].[sp_requestpeertopologyinfo] TO [public] AS [dbo]
GO
