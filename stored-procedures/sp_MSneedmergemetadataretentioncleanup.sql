SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSneedmergemetadataretentioncleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSneedmergemetadataretentioncleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSneedmergemetadataretentioncleanup]
	@replicaid [uniqueidentifier],
	@needcleanup [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @REPLICA_STATUS_BeforeRestore tinyint
    declare @pubid uniqueidentifier
    declare @metadatacleanuptime datetime
    declare @retcode int

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @replicaid
    if @@error<>0 or @retcode<>0
        return 1

    set @REPLICA_STATUS_BeforeRestore= 7
    set @needcleanup = 0

    select @pubid = pubid, @metadatacleanuptime = metadatacleanuptime from dbo.sysmergesubscriptions
    where subid=@replicaid and
    status<>@REPLICA_STATUS_BeforeRestore

    if @pubid is not null
        select @needcleanup= case when 
                                    sys.fn_add_units_to_date(-1, retention_period_unit, getdate()) > @metadatacleanuptime 
                                        then 1
                                    else 0
                             end
        from dbo.sysmergepublications
        where pubid = @pubid

GO
GRANT EXECUTE ON [sys].[sp_MSneedmergemetadataretentioncleanup] TO [public] AS [dbo]
GO
