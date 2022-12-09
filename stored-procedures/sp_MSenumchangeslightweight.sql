SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumchangeslightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumchangeslightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumchangeslightweight]
	@pubid [uniqueidentifier],
	@tablenick [int],
	@lastrowguid [uniqueidentifier],
	@maxrows [int]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @retcode 	int
	declare @postfix	nchar(32)
	declare @procname	sysname
	declare @pubnick	int
	declare @METADATA_TYPE_InsertLightweight tinyint
	declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @maxint  int


	-- do permission checking
	exec @retcode = sys.sp_MSreplcheck_subscribe
	if @retcode<>0 or @@ERROR<>0 return (1)

	set @METADATA_TYPE_InsertLightweight= 7 
	set @METADATA_TYPE_UpdateLightweight= 8
    set @maxint= 2147483647

    if 0 = @maxrows
    begin
        set @maxrows= @maxint
    end
    
	select @pubnick = sync_info from dbo.MSmerge_replinfo where repid = @pubid

	select @postfix= procname_postfix
		from dbo.sysmergearticles 
		where pubid = @pubid and nickname = @tablenick
	
	set @procname= quotename('MSmerge_lws_sp_multi_' + @postfix)

	-- Step 1: Set the sync_cookie value for the updates/inserts that will be enumerated.
	-- 		   That sync_cookie will be reset upon downloading the proxied metadata
	--		   from that publisher.
	-- Step 2: Enumerate all those rows whose sync_cookie has just been set.
	--

	-- Step 1
	update dbo.MSmerge_rowtrack
		set sync_cookie= @pubnick
		where tablenick = @tablenick and
			  rowguid > @lastrowguid and
			  changetype in (@METADATA_TYPE_InsertLightweight,
			  				 @METADATA_TYPE_UpdateLightweight)

	-- Step 2
	exec @retcode= @procname 
						@action= 2, 
						@pubnick= @pubnick, 
						@rowguid= @lastrowguid,
						@maxrows= @maxrows
	if @@error <> 0 or @retcode <> 0 return 1

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSenumchangeslightweight] TO [public] AS [dbo]
GO
