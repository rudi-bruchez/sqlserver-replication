SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_dynamic_snapshot_location]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_dynamic_snapshot_location] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_dynamic_snapshot_location]
	@publication [sysname],
	@partition_id [int],
	@dynsnap_location [nvarchar](255)
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode  int
	
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@ERROR<>0
        return 1

    if @partition_id is NULL or @partition_id < 0
        return 0
        
    if exists(select * from dbo.MSmerge_dynamic_snapshots where partition_id = @partition_id)
    begin
        update dbo.MSmerge_dynamic_snapshots
        set dynamic_snapshot_location = @dynsnap_location, last_updated = getdate()
        where partition_id = @partition_id
        if @retcode <> 0 or @@error <> 0
            return 1
    end
    else
    begin
        insert into dbo.MSmerge_dynamic_snapshots (partition_id, dynamic_snapshot_location, last_updated, last_started)
        values (@partition_id, @dynsnap_location, getdate(), NULL)
        if @retcode <> 0 or @@error <> 0
            return 1
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSadd_dynamic_snapshot_location] TO [public] AS [dbo]
GO
