SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSexecwithlsnoutput]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSexecwithlsnoutput] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSexecwithlsnoutput]
	@command [nvarchar](max),
	@xact_seqno [varbinary](16) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int

	select @xact_seqno = 0x0
	
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

	begin transaction tran_sp_MSexecwithlsnoutput
	save transaction tran_sp_MSexecwithlsnoutput

	exec(@command)
	if @@error <> 0
    begin
        goto FAILURE
    end

    -- if this is not a republisher we will get an error. this is expected
    -- since we should never be calling this on a non-publisher database.
	exec @retcode = sys.sp_replincrementlsn @xact_seqno = @xact_seqno output
	if @@error <> 0 or @retcode <> 0 
	begin
		goto FAILURE
	end

	commit transaction tran_sp_MSexecwithlsnoutput
	
    return 0
FAILURE:
	rollback transaction tran_sp_MSexecwithlsnoutput
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSexecwithlsnoutput] TO [public] AS [dbo]
GO
