SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_requestpeerresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_requestpeerresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_requestpeerresponse]
	@publication [sysname],
	@description [nvarchar](4000),
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
		raiserror(15002, 16, -1, 'sp_requestpeerresponse')
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
        raiserror (14043, 16, -1, @publication, 'sp_requestpeerresponse')
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

	-- if there are no matching peer subscriptions  
	-- we will just raise an error and exit out...
	if not exists(select * 
					from MSpeer_lsns
					where (originator != UPPER(@originator)
							or originator_db != @originator_db)
						and originator_publication = @publication)
	begin
		-- No Peers were found for @originator:@originator_db:@publication.
		raiserror(20807, 16, -1, @originator, @originator_db, @publication)
		return 1
	end
	
	begin transaction tr_sp_requestpeerresponse
	save transaction tr_sp_requestpeerresponse

	insert into MSpeer_request
		(
			publication, 
			description
		) 
		values
		(
			@publication, 
			@description	
		)
	if @@error <> 0 
	begin
		-- The procedure sys.sp_requestpeerresponse failed to INSERT into the resource MSpeer_request. Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_requestpeerresponse', 'INSERT into', 'MSpeer_request.', @@error)
		goto FAILURE
	end

	select @request_id = scope_identity()

	insert into MSpeer_response
		(
			request_id,
			peer,
			peer_db
		)
		select distinct @request_id,
				UPPER(originator),
				originator_db
			from MSpeer_lsns
			where (originator != UPPER(@originator)
					or originator_db != @originator_db)
				and originator_publication = @publication
	if @@error <> 0
	begin
		-- The procedure sys.sp_requestpeerresponse failed to INSERT into the resource MSpeer_response. Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_requestpeerresponse', 'INSERT into', 'MSpeer_response.', @@error)
		goto FAILURE
	end

	select @cmd = N'exec sys.sp_MSpeersendresponse @request_id=' + cast(@request_id as nvarchar) + 
												N',@originator=N' + quotename(@originator, '''') + 
												N',@originator_db=N' + quotename(@originator_db, '''') +
												N',@originator_publication=N' + quotename(@publication, '''')
	
	exec @retcode = sys.sp_MSpeertopeerfwdingexec @command = @cmd,
													@publication = @publication,
													@execute = 0,
													@change_results_originator = 1
	if @@error <> 0 or @retcode <> 0
		goto FAILURE

	commit transaction tr_sp_requestpeerresponse

	return 0
FAILURE:
	rollback transaction tr_sp_requestpeerresponse
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_requestpeerresponse] TO [public] AS [dbo]
GO
