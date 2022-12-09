SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetlastsentrecgens]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetlastsentrecgens] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetlastsentrecgens]
	@repid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode    int

    if (@repid is null)
        begin
            RAISERROR(14043, 16, -1, '@repid', 'sp_MSgetlastsentrecgens')
            return (1)
        end

    /*
    ** do permission checking
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
    if @retcode<>0 or @@ERROR<>0 return (1)
        
    select sentgen, sentguid, recgen, recguid from dbo.sysmergesubscriptions where subid = @repid
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetlastsentrecgens] TO [public] AS [dbo]
GO
