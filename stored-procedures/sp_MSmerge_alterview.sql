SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_alterview]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_alterview] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_alterview]
	@qual_object_name [nvarchar](512),
	@objid [int],
	@pass_through_scripts [nvarchar](max),
	@objecttype [varchar](32)
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    if is_member('db_owner') <> 1
    begin
        raiserror (21050, 16, -1)
        return (1)
    end

    begin tran
    save TRAN sp_MSmerge_alterview

    -- obtain the snapshot/DDL/admin proc applock to avoid having contention with snapshot
    -- Attempt to get the lock with no wait
    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(21386, 16, -1, @qual_object_name)
        goto FAILURE
    end

    select @got_merge_admin_applock = 1

    --loop through schema only publications/articles
    exec @retcode = sys.sp_MSmerge_alterschemaonly @qual_object_name = @qual_object_name
                                                ,@objid = @objid
                                                ,@pass_through_scripts = @pass_through_scripts
                                                ,@objecttype = @objecttype
    if @retcode <>0 or @@ERROR<>0
        goto FAILURE

    --merge does not have table based publications/articles for now
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    commit tran
    return 0

FAILURE:
    IF @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION sp_MSmerge_alterview
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_alterview] TO [public] AS [dbo]
GO
