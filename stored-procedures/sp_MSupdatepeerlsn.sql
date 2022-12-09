SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdatepeerlsn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdatepeerlsn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdatepeerlsn]
	@originator [sysname],
	@originator_db [sysname],
	@originator_publication_id [int],
	@originator_db_version [int],
	@originator_lsn [varbinary](10)
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 		bit,
			@error			int,
			@rows_affected	int
	
	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or  @retcode <> 0 
    begin
        return 1
    end

	begin transaction tran_sp_MSupdatepeerlsn
	save transaction tran_sp_MSupdatepeerlsn
	
	-- update the peer_lsn
	update MSpeer_lsns
		set last_updated 	= getdate(),
			originator_lsn 	= @originator_lsn
		from MSpeer_lsns with (index(uci_MSpeer_lsns))
		where originator					= UPPER(@originator)
			and originator_db 				= @originator_db
			and originator_publication_id	= @originator_publication_id 
			and originator_db_version		= @originator_db_version
			and originator_lsn				<= @originator_lsn

	-- cache the row count and error
	select @rows_affected 	= @@rowcount,
			@error			= @@error

	-- if we hit an error let the user know and exit
	if @error <> 0
	begin
		goto FAILURE
	end

	-- if row count is 0 then we know we are not a peer and the subcription is not found.
	if @rows_affected <> 1
	begin
		declare @pub_id varchar(10)

		select @pub_id = cast(@originator_publication_id as varchar)

		-- No peers were found for %s:%s:%s.
		raiserror(20807, 16, -1, @originator, @originator_db, @pub_id)
		goto FAILURE
	end

	commit transaction tran_sp_MSupdatepeerlsn
	
	return 0
FAILURE:
	rollback transaction tran_sp_MSupdatepeerlsn
	commit transaction tran_sp_MSupdatepeerlsn

	-- The procedure sys.sp_MSupdatepeerlsn failed to UPDATE the resource MSpeer_lsns. Server error =  0.
	raiserror (21499, 16, -1, 'sys.sp_MSupdatepeerlsn', 'UPDATE', 'MSpeer_lsns.', @error)

	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSupdatepeerlsn] TO [public] AS [dbo]
GO
