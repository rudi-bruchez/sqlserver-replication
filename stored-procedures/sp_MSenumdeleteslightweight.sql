SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumdeleteslightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumdeleteslightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumdeleteslightweight]
	@pubid [uniqueidentifier],
	@tablenick [int],
	@lastrowguid [uniqueidentifier],
	@maxrows [int]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @pubnick	int
	declare @METADATA_TYPE_DeleteLightweight tinyint
	declare @last_art_processing_order int
	declare @maxint int
	declare @retcode int

    -- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0 or @@error <> 0)
        return 1

	set @METADATA_TYPE_DeleteLightweight= 10
	set @maxint= 2147483647

    if 0 = @maxrows
    begin
        set @maxrows= @maxint
    end
    
	select @pubnick = sync_info from dbo.MSmerge_replinfo where repid = @pubid

	-- Step 1: Set the localid value for the deletes that will be enumerated.
	-- 		   That localid will be reset upon downloading the proxied metadata
	--		   from that publisher.
	-- Step 2: Enumerate all those rows whose localid has just been set.
	--
	if @tablenick = 0
	begin
		-- Step 1
		update rt
			set rt.sync_cookie= @pubnick
			from dbo.MSmerge_rowtrack rt join dbo.sysmergearticles art
			on rt.tablenick = art.nickname
			where art.pubid = @pubid and
				  rt.changetype = @METADATA_TYPE_DeleteLightweight

		-- Step 2
		select top (@maxrows) rt.tablenick, rt.rowguid, rt.rowvector
			from dbo.MSmerge_rowtrack rt join dbo.sysmergearticles art
			on rt.tablenick = art.nickname
			where art.pubid = @pubid and
				  rt.changetype = @METADATA_TYPE_DeleteLightweight and
				  rt.sync_cookie = @pubnick
			order by art.processing_order desc, rt.tablenick desc, rt.rowguid asc
	end
	else
	begin
		exec sys.sp_MSget_lightweightarticle_processing_order @tablenick, @pubid, @last_art_processing_order output
		
		-- Step 1
		update rt
			set rt.sync_cookie= @pubnick
			from dbo.MSmerge_rowtrack rt join dbo.sysmergearticles art
			on rt.tablenick = art.nickname
			where art.pubid = @pubid and
				  rt.changetype = @METADATA_TYPE_DeleteLightweight and
				  ((rt.tablenick = @tablenick and rt.rowguid > @lastrowguid)
					or
					(art.processing_order = @last_art_processing_order and rt.tablenick < @tablenick)
					or 
					art.processing_order < @last_art_processing_order
				  )

		-- Step 2
		select top (@maxrows) rt.tablenick, rt.rowguid, rt.rowvector
			from dbo.MSmerge_rowtrack rt join dbo.sysmergearticles art
			on rt.tablenick = art.nickname
			where art.pubid = @pubid and
				  rt.changetype = @METADATA_TYPE_DeleteLightweight and
				  ((rt.tablenick = @tablenick and rt.rowguid > @lastrowguid)
					or
					(art.processing_order = @last_art_processing_order and rt.tablenick < @tablenick)
					or 
					art.processing_order < @last_art_processing_order
				  ) and
				  rt.sync_cookie = @pubnick
			order by art.processing_order desc, rt.tablenick desc, rt.rowguid asc
	end

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSenumdeleteslightweight] TO [public] AS [dbo]
GO
