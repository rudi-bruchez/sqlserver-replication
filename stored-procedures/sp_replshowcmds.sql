SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replshowcmds]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replshowcmds] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replshowcmds]
	@maxtrans [int]
WITH EXECUTE AS CALLER
AS
begin

    set nocount on
    declare @query nvarchar(1024)
                ,@retcode int

    /*
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    if (sys.fn_MSrepl_istranpublished (db_name(),0) != 1)
    begin
        raiserror(18757, 16, -1)
        return (1)
    end

    select @query = N'exec sys.sp_replcmds ' + cast (@maxtrans as nvarchar(12))
    execute @retcode = sys.sp_printstatement @query
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_replshowcmds] TO [public] AS [dbo]
GO
