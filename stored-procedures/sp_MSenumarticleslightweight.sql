SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumarticleslightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumarticleslightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumarticleslightweight]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
	exec @retcode= sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0 return (1)

	select 
		a.name, a.destination_object, a.artid, a.pubid, a.nickname, 
		a.column_tracking, a.destination_owner, a.identity_support, a.well_partitioned_lightweight,
		a.processing_order, a.upload_options, i.range, i.threshold, a.delete_tracking, a.compensate_for_errors,
		a.stream_blob_columns
		from dbo.sysmergearticles a left outer join dbo.MSmerge_idrange i on a.objid = i.objid
		where a.pubid=@pubid and
			  a.lightweight=1
GO
GRANT EXECUTE ON [sys].[sp_MSenumarticleslightweight] TO [public] AS [dbo]
GO
