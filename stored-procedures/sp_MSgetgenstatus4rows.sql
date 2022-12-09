SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetgenstatus4rows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetgenstatus4rows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetgenstatus4rows]
	@repid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode    int

    if (@repid is null)
        begin
            RAISERROR(14043, 16, -1, '@repid', 'sp_MSgetgenstatus4rows')
            return (1)
        end

    /*
    ** do permission checking
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
    if @retcode<>0 or @@ERROR<>0 return (1)
        
    select guidsrc, generation from dbo.MSmerge_genhistory where genstatus = 4 and subscriber_number = (select subscriber_number from dbo.sysmergesubscriptions where subid = @repid) order by generation 
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetgenstatus4rows] TO [public] AS [dbo]
GO
