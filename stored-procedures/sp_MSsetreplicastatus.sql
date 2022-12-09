SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetreplicastatus]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetreplicastatus] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetreplicastatus]
	@subid [uniqueidentifier],
	@status_value [int]
WITH EXECUTE AS CALLER
AS
/*
    ** Check to see if current publication has permission
    */
    declare @retcode int

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @subid
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    if object_id(N'dbo.sysmergesubscriptions','U') is null
        return 0
    
     IF EXISTS (select subid from dbo.sysmergesubscriptions where subid=@subid)
        begin
            update dbo.sysmergesubscriptions set status = @status_value,
                cleanedup_unsent_changes = case when @status_value=1 then 0 else cleanedup_unsent_changes end   
            WHERE subid=@subid               
            if @@ERROR<>0 return (1)

            if @status_value = 1
            begin
                -- update the publisher replica row's cleanedup_unsent_changes as well.
                update dbo.sysmergesubscriptions set cleanedup_unsent_changes = 0
                WHERE subid = (select top 1 pubid from dbo.sysmergesubscriptions where subid = @subid)               
                if @@ERROR<>0 return (1)
            end

            update dbo.MSmerge_replinfo set resync_gen=-1 WHERE repid=@subid               
            if @@ERROR<>0 return (1)
        end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetreplicastatus] TO [public] AS [dbo]
GO
