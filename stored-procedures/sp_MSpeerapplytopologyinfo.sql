SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerapplytopologyinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerapplytopologyinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerapplytopologyinfo]
	@request_id [int],
	@originator [sysname],
	@originator_db [sysname],
	@response_srvr [sysname],
	@response_db [sysname],
	@connection_info [xml],
	@response_srvr_version [int],
	@response_originator_id [int],
	@response_conflict_retention [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on	
	
	declare @retcode int
	
	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
       if @@error <> 0 or @retcode <> 0 
       begin
           return 1
       end

	-- we will exit in either of these conditions since this means we
	-- are not at the correct node and we should treat this as a noop
	-- the conditions are as follows:
	--	1. Any of the user provided information is NULL
	--	2. We are not on the originator server
	--	3. (NOT USED) The originator and reponse_srvr are the same
	--
	-- section 1 
	if @request_id is NULL
		or @originator is NULL
		or @originator_db is NULL
		or @response_srvr is NULL
		or @response_db is NULL
		-- section 2
		or UPPER(@originator) <> UPPER(publishingservername())
		or @originator_db <> db_name()
		-- we do not need the 3rd condition since we want topology from the originator as well
		---- section 3
		--or (UPPER(@originator) = UPPER(@response_srvr)
		--	and @originator_db = @response_db)
	begin
		return 0
	end
	
	begin transaction tr_sp_MSpeerapplytopologyinfo
	save transaction tr_sp_MSpeerapplytopologyinfo

	if @response_originator_id = 0 
	begin
		select @response_originator_id = NULL
		select @response_conflict_retention = NULL
	end
	
	update MSpeer_topologyresponse
		set received_date = getdate(),
			connection_info = @connection_info,
			peer_version = @response_srvr_version,
			originator_id = @response_originator_id,
			peer_conflict_retention = @response_conflict_retention
		where request_id = @request_id
			and peer = @response_srvr
			and peer_db = @response_db
	if @@error <> 0
	begin
		-- The procedure sys.MSpeer_topologyresponse failed to UPDATE the resource MSpeer_topologyresponse Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_MSpeerapplytopologyinfo', 'UPDATE', 'MSpeer_topologyresponse.', @@error)
		goto FAILURE
	end

	--update the peer node version inside MSpeer_lsns
	if @response_srvr_version is not null
	begin
		update MSpeer_lsns
		set originator_version = @response_srvr_version
		where originator = @response_srvr 
			and originator_db = @response_db
			and originator_publication = (select  publication from MSpeer_topologyrequest where id = @request_id)
			and originator_version <> @response_srvr_version
	end
	
	commit transaction tr_sp_MSpeerapplytopologyinfo

	return 0
FAILURE:
	rollback transaction tr_sp_MSpeerapplytopologyinfo
	commit transaction 
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeerapplytopologyinfo] TO [public] AS [dbo]
GO
