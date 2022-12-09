SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerapplyresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerapplyresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerapplyresponse]
	@request_id [int],
	@originator [sysname],
	@originator_db [sysname],
	@response_srvr [sysname],
	@response_db [sysname]
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
	--	3. The originator and reponse_srvr are the same
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
		-- section 3
		or (UPPER(@originator) = UPPER(@response_srvr)
			and @originator_db = @response_db)
	begin
		return 0
	end
	
	begin transaction tr_sp_MSpeerapplyresponse
	save transaction tr_sp_MSpeerapplyresponse

	update MSpeer_response
		set received_date = getdate()
		where request_id = @request_id
			and peer = @response_srvr
			and peer_db = @response_db
	if @@error <> 0
	begin
		-- The procedure sys.sp_MSpeerapplyresponse failed to UPDATE the resource MSpeer_response Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_MSpeerapplyresponse', 'UPDATE', 'MSpeer_response.', @@error)
		goto FAILURE
	end

	commit transaction tr_sp_MSpeerapplyresponse

	return 0
FAILURE:
	rollback transaction tr_sp_MSpeerapplyresponse
	commit transaction 
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeerapplyresponse] TO [public] AS [dbo]
GO
