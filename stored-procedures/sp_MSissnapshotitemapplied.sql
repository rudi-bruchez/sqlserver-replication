SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSissnapshotitemapplied]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSissnapshotitemapplied] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSissnapshotitemapplied]
	@snapshot_session_token [nvarchar](260),
	@snapshot_progress_token [nvarchar](500)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @snapshot_progress_token_hash int
    select @retcode = 0

    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end

    if object_id('dbo.MSsnapshotdeliveryprogress') is not null
    begin
        select @snapshot_progress_token_hash = 
            sys.fn_repl32bitstringhash(@snapshot_progress_token)
        if @@error <> 0
        begin
            select @retcode = 1
            goto FAILURE
        end
        if exists (select * from MSsnapshotdeliveryprogress    
                    where progress_token_hash = @snapshot_progress_token_hash
                      and progress_token = @snapshot_progress_token
                      and session_token = @snapshot_session_token)
        begin
            select 'snapshot_item_applied' = 1
        end
        else
        begin
            select 'snapshot_item_applied' = 0
        end
        if @@error <> 0
        begin
            select @retcode = 1
            goto FAILURE
        end
    end
    else
    begin
        select 'snapshot_item_applied' = 0
    end
    if @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
FAILURE:
    return @retcode    
end
GO
GRANT EXECUTE ON [sys].[sp_MSissnapshotitemapplied] TO [public] AS [dbo]
GO
