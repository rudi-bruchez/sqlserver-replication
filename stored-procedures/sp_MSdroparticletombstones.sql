SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdroparticletombstones]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdroparticletombstones] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdroparticletombstones]
	@artid [uniqueidentifier],
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @progress_token nvarchar(500)
    declare @progress_token_hash int
    declare @session_token nvarchar(260)
    declare @retcode int
    
    -- Security Checking 
    -- PAL user access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @artid = @artid
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if @pubid is not null -- Coming from a 9.0 agent
    begin
        if object_id('dbo.MSsnapshotdeliveryprogress', 'U') is not null
        begin    
            select @session_token = null,
                   @progress_token = N'<MergePubId>:' + convert(nvarchar(100), @pubid),
                   @progress_token_hash = sys.fn_repl32bitstringhash(@progress_token)
            -- Try to get the session token from the merge pubid
            select @session_token = session_token 
              from dbo.MSsnapshotdeliveryprogress
             where progress_token_hash = @progress_token_hash
               and progress_token = @progress_token
            if @session_token is not null
            begin
                select @progress_token = N'<DroppedArticleTombstones>:' + convert(nvarchar(100), @artid),
                       @progress_token_hash = sys.fn_repl32bitstringhash(@progress_token)
                if exists (select * from dbo.MSsnapshotdeliveryprogress
                            where session_token = @session_token
                              and progress_token_hash = @progress_token_hash
                              and progress_token = @progress_token)
                begin
                    -- Meta-data table had been cleaned up by an interrupted
                    -- snapshot session before, don't do it again
                    return (0)
                end
                else
                begin
                    exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress 
                            @snapshot_session_token = @session_token,
                            @snapshot_progress_token = @progress_token
                    if @@error <> 0 or @retcode <> 0 return (1)
                            
                end                
            end
        end
    end

    declare @tablenick int
    select @tablenick = nickname from dbo.sysmergearticles where artid = @artid
    if @tablenick is not null
    begin
        delete from dbo.MSmerge_tombstone where tablenick = @tablenick
        delete from dbo.MSmerge_current_partition_mappings where tablenick = @tablenick
        delete from dbo.MSmerge_past_partition_mappings where tablenick = @tablenick
        delete from dbo.MSmerge_contents where tablenick = @tablenick
        delete from dbo.MSmerge_generation_partition_mappings where generation in
            (select generation from dbo.MSmerge_genhistory where art_nick=@tablenick)
        delete from dbo.MSmerge_genhistory where art_nick=@tablenick
    end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSdroparticletombstones] TO [public] AS [dbo]
GO
