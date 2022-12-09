SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_latest_peerlsn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_latest_peerlsn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_latest_peerlsn]
	@originator_publication [sysname],
	@originator [sysname],
	@originator_db [sysname],
	@xact_seqno [binary](10) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int    

    --
    -- Security check
    --
    exec @retcode = sp_MSreplcheck_subscribe
    if @@error != 0 or @retcode != 0
        return 1

    select @xact_seqno = originator_lsn from MSpeer_lsns with (NOLOCK)
        where originator = UPPER(@originator) and
              originator_db = @originator_db and
              originator_publication = @originator_publication
    
    if @@error <> 0
        return(1)
    
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_latest_peerlsn] TO [public] AS [dbo]
GO
