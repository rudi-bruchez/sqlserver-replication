SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinitdynamicsubscriber]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinitdynamicsubscriber] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinitdynamicsubscriber]
	@maxrows [int],
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@compatlevel [int],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit]
WITH EXECUTE AS CALLER
AS
declare @retcode        smallint
    declare @procname       nvarchar(290)

    -- Security Checking 
    -- PAL user access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1

        
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSinitdynamicsubscriber')
        return (1)
    end
    select @procname = view_sel_proc from dbo.sysmergearticles where
            pubid = @pubid and nickname = @tablenick

    exec @retcode= @procname 
                        @tablenick= @tablenick, 
                        @max_rows= @maxrows, 
                        @guidlast= @rowguid, 
                        @compatlevel= @compatlevel, 
                        @pubid= @pubid,
                        @enumentirerowmetadata= @enumentirerowmetadata,
                        @blob_cols_at_the_end = @blob_cols_at_the_end

    if @@ERROR<>0 or @retcode<>0 
    begin
        return (1)
    end 
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSinitdynamicsubscriber] TO [public] AS [dbo]
GO
