SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSregistermergesnappubid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSregistermergesnappubid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSregistermergesnappubid]
	@snapshot_session_token [nvarchar](260),
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @pubidprefix nvarchar(100)
    declare @transaction_opened bit
    declare @snapshot_progress_token nvarchar(500)
    declare @snapshot_progress_token_hash nvarchar(500)
    declare @previous_snapshot_session_token nvarchar(260)

    select @retcode = 0
    select @pubidprefix = N'<MergePubId>:'
    select @transaction_opened = 0
    select @snapshot_progress_token = @pubidprefix + convert(nvarchar(100), @pubid)
    select @snapshot_progress_token_hash = sys.fn_repl32bitstringhash(@snapshot_progress_token)
    select @previous_snapshot_session_token = null
   
    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

    begin transaction
    save transaction sp_MSregistermergesnappubid
    if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
    select @transaction_opened = 1

    -- Try to pick up the session token of a previously interrupted snapshot
    -- delivery session for this publication
    if object_id('dbo.MSsnapshotdeliveryprogress', 'U') is not null
    begin

        select @previous_snapshot_session_token = session_token
          from dbo.MSsnapshotdeliveryprogress
         where progress_token_hash = @snapshot_progress_token_hash
           and progress_token = @snapshot_progress_token
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

        -- The current snapshot is different from the one interrupted before, 
        -- need to do cleanup of the interrupted snapshot            
        if @previous_snapshot_session_token is not null and
           @previous_snapshot_session_token <> @snapshot_session_token
        begin
            exec @retcode = sys.sp_MSpurgepartialmergesnapshot 
                    @pubid = @pubid
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
            exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                    @snapshot_session_token = @snapshot_session_token,
                    @snapshot_progress_token = @snapshot_progress_token
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
        end
        else if @previous_snapshot_session_token is null
        begin
            exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                    @snapshot_session_token = @snapshot_session_token,
                    @snapshot_progress_token = @snapshot_progress_token
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
        end
    end
    else
    begin
        exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                @snapshot_session_token = @snapshot_session_token,
                @snapshot_progress_token = @snapshot_progress_token
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
    end

    commit transaction
    if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
    select @transaction_opened = 0
    
Failure:
    if @transaction_opened = 1
    begin
        rollback transaction sp_MSregistermergesnappubid
        commit transaction
    end
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSregistermergesnappubid] TO [public] AS [dbo]
GO
