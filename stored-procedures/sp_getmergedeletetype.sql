SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getmergedeletetype]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getmergedeletetype] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getmergedeletetype]
	@source_object [nvarchar](386),
	@rowguid [uniqueidentifier],
	@delete_type [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @object			sysname	 
	declare @owner			sysname	 
	declare @tablenick		int
	declare @retcode		int

	-- Security check: dbo and sysadmin only
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end	   
	
	select @object = PARSENAME(@source_object, 1)
	select @owner = PARSENAME(@source_object, 2)
	execute sys.sp_MStablenickname @owner, @object, @tablenick output
	if @tablenick IS NULL OR @@ERROR<>0
		BEGIN
			raiserror (20003, 11, -1, @object)
			RETURN (1)
		END

	if @rowguid IS NULL 
		begin
			raiserror (14027, 11, -1, '@rowguid')
			return (1)
		end
		
	select @delete_type = type from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick
GO
GRANT EXECUTE ON [sys].[sp_getmergedeletetype] TO [public] AS [dbo]
GO
