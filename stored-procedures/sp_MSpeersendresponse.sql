SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeersendresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeersendresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeersendresponse]
	@request_id [int],
	@originator [sysname],
	@originator_db [sysname],
	@originator_publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode		int,
			@cmd			nvarchar(4000),
			@response_srvr	sysname,
			@response_db	sysname

	-- security check for subscriber
	-- Though the work below is related to a publisher, we use 
	-- a check for the subscriber because this is normally executed
	-- by the distribution agent at a subscriber (republisher).
	-- this should only be used by peer to peer subscribers.
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or @retcode <> 0 
    begin
        return 1
    end

	select @cmd = NULL,
			@response_srvr = publishingservername(),
			@response_db = db_name()

	-- if are on the originator then no-op
	if UPPER(@originator) = UPPER(@response_srvr)
			and @originator_db = @response_db
	begin
		return 0
	end
			
	begin transaction tr_sp_MSpeersendresponse
	save transaction tr_sp_MSpeersendresponse

	select @cmd = N'exec sys.sp_MSpeerapplyresponse @request_id=' + cast(@request_id as nvarchar) +
												N',@originator=N' + quotename(@originator, '''') +
												N',@originator_db=N' + quotename(@originator_db, '''') +
												N',@response_srvr=N' + quotename(@response_srvr, '''') +
												N',@response_db=N' + quotename(@response_db, '''')

	exec @retcode = sys.sp_MSpeertopeerfwdingexec @command = @cmd,
													@publication = @originator_publication
	if @@error <> 0 or @retcode <> 0
		goto FAILURE

	commit transaction tr_sp_MSpeersendresponse

	return 0
FAILURE:
	rollback transaction tr_sp_MSpeersendresponse
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeersendresponse] TO [public] AS [dbo]
GO
