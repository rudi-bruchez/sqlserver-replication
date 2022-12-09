SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSregisterdynsnapseqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSregisterdynsnapseqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSregisterdynsnapseqno]
	@snapshot_session_token [nvarchar](260),
	@dynsnapseqno [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @dynsnapseqnoprefix nvarchar(100)    
    declare @pubidprefix nvarchar(100)
    declare @snapshot_progress_token nvarchar(500)    
    declare @transaction_opened bit
    declare @previous_dynsnapseqno uniqueidentifier
    declare @snapshot_progress_token_hash int
    declare @pubid uniqueidentifier

    -- Initializations
    select @retcode = 0
    select @dynsnapseqnoprefix = N'<DynSnapSeqNo>:'    
    select @pubidprefix = N'<MergePubId>:'    
    select @transaction_opened = 0
    
    select @previous_dynsnapseqno = null

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
    
    if object_id('dbo.MSsnapshotdeliveryprogress', 'U') is not null
    begin

        -- Try to get the previous dynamic snapshot sequence number
        select @previous_dynsnapseqno = 
                    convert(uniqueidentifier, right(progress_token, len(progress_token) - len(@dynsnapseqnoprefix)))
          from dbo.MSsnapshotdeliveryprogress   
         where session_token = @snapshot_session_token
           and left(progress_token, len(@dynsnapseqnoprefix)) = @dynsnapseqnoprefix
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

        -- If the dynamic snapshot sequence number is different, cleanup
        -- everything for the new dynamic snapshot
        if @previous_dynsnapseqno is not null and
           @previous_dynsnapseqno <> @dynsnapseqno
        begin    
            begin transaction
            save transaction sp_MSregisterdynsnapseqno
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
            select @transaction_opened = 1
                                
            -- Try to get the pubid for this snapshot
            select @pubid =
                    convert(uniqueidentifier, right(progress_token, len(progress_token) - len(@pubidprefix)))
              from dbo.MSsnapshotdeliveryprogress
             where session_token = @snapshot_session_token
               and left(progress_token, len(@pubidprefix)) = @pubidprefix

            -- Do cleanup
            exec @retcode = sys.sp_MSpurgepartialmergesnapshot
                    @pubid = @pubid
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            -- Register both the pubid and the dynsnapseqno again because
            -- both registrations would have been removed by the cleanup above
            select @snapshot_progress_token = @pubidprefix + convert(nvarchar(100), @pubid)
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                    @snapshot_session_token = @snapshot_session_token,
                    @snapshot_progress_token = @snapshot_progress_token
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            select @snapshot_progress_token = @dynsnapseqnoprefix + convert(nvarchar(100), @dynsnapseqno)
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                    @snapshot_session_token = @snapshot_session_token,
                    @snapshot_progress_token = @snapshot_progress_token
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            commit transaction        
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
            select @transaction_opened = 0
        end
        else if @previous_dynsnapseqno is null
        begin
            select @snapshot_progress_token = @dynsnapseqnoprefix + convert(nvarchar(100), @dynsnapseqno)
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

            exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                    @snapshot_session_token = @snapshot_session_token,
                    @snapshot_progress_token = @snapshot_progress_token
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
        end
    end    
    else
    begin
        select @snapshot_progress_token = @dynsnapseqnoprefix + convert(nvarchar(100), @dynsnapseqno)
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

        exec @retcode = sys.sp_MSrecordsnapshotdeliveryprogress
                @snapshot_session_token = @snapshot_session_token,
                @snapshot_progress_token = @snapshot_progress_token
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
    end

Failure:
    if @transaction_opened = 1
    begin
        rollback transaction sp_MSregisterdynsnapseqno
        commit transaction
    end

    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSregisterdynsnapseqno] TO [public] AS [dbo]
GO
