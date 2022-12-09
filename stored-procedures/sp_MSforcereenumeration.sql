SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSforcereenumeration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSforcereenumeration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSforcereenumeration]
	@tablenick [int],
	@rowguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @METADATA_TYPE_DeleteLightweight tinyint
	declare @METADATA_TYPE_DeleteLightweightProcessed tinyint

	declare @COLUMNS_ENUMERATED_AllOnConflictOrError int
	declare @retcode int

	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1

	set @METADATA_TYPE_UpdateLightweight= 8
	set @METADATA_TYPE_DeleteLightweight= 10
	set @METADATA_TYPE_DeleteLightweightProcessed= 12

	set @COLUMNS_ENUMERATED_AllOnConflictOrError= 1

	update dbo.MSmerge_rowtrack
		set changetype= case changetype
							when @METADATA_TYPE_DeleteLightweightProcessed then @METADATA_TYPE_DeleteLightweight
							when @METADATA_TYPE_DeleteLightweight then @METADATA_TYPE_DeleteLightweight
							else @METADATA_TYPE_UpdateLightweight
						end,
			columns_enumeration= case changetype
									when @METADATA_TYPE_DeleteLightweightProcessed then columns_enumeration
									when @METADATA_TYPE_DeleteLightweight then columns_enumeration
									else @COLUMNS_ENUMERATED_AllOnConflictOrError
								 end,
			changed= sys.fn_MSdayasnumber(getdate())
		where tablenick = @tablenick and 
			  rowguid = @rowguid

	if @@error <> 0 return 1

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSforcereenumeration] TO [public] AS [dbo]
GO
