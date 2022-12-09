SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetlastrecgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetlastrecgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetlastrecgen]
	@repid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode    int

    /*
    ** do permission checking
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
    if @retcode<>0 or @@ERROR<>0 return (1)

    if object_id('MSmerge_contents') is NULL and 
       object_id('MSmerge_rowtrack') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    if (@repid is null)
    begin
        RAISERROR(14043, 16, -1, '@repid', 'sp_MSgetlastrecgen')
        return (1)
    end

    select recgen, recguid from dbo.sysmergesubscriptions where subid = @repid
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetlastrecgen] TO [public] AS [dbo]
GO
