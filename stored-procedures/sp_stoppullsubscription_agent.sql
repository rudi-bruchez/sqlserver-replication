SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_stoppullsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_stoppullsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_stoppullsubscription_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
            ,@stop tinyint

    set @retcode = 0
    set @stop = 1

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return 1

    exec @retcode = sys.sp_MSpullsubscriptionagentjobcontrol
        @publisher = @publisher,
        @publisher_db = @publisher_db,
        @publication = @publication,
        @action = @stop
    return @retcode 
end
GO
GRANT EXECUTE ON [sys].[sp_stoppullsubscription_agent] TO [public] AS [dbo]
GO
