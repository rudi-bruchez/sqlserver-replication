SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrequestreenumeration_lightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrequestreenumeration_lightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrequestreenumeration_lightweight]
	@tablenick [int],
	@rowguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
	declare @err int
	declare @rc int
	declare @METADATA_ACTION_ForceReenumeration tinyint

	set @METADATA_ACTION_ForceReenumeration= 5

	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1

	update dbo.MSmerge_metadataaction_request
		set action= @METADATA_ACTION_ForceReenumeration,
			generation=null,
			changed= sys.fn_MSdayasnumber(getdate())
		where tablenick=@tablenick and rowguid=@rowguid

	select @err= @@error, @rc=@@rowcount
	if @err<>0 return 1
	if @rc>0 return 0

	insert into dbo.MSmerge_metadataaction_request
						(tablenick,
						 rowguid,
						 action,
						 generation,
						 changed)
					values
						(@tablenick,
						 @rowguid,
						 @METADATA_ACTION_ForceReenumeration,
						 null,
						 sys.fn_MSdayasnumber(getdate()))
						 
	if @err<>0 return 1
	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSrequestreenumeration_lightweight] TO [public] AS [dbo]
GO
