SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrecordsnapshotdeliveryprogress]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrecordsnapshotdeliveryprogress] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrecordsnapshotdeliveryprogress]
	@snapshot_session_token [nvarchar](260),
	@snapshot_progress_token [nvarchar](500)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    set arithabort on
    declare @retcode int
    declare @snapshot_progress_token_hash int
    select @retcode = 0

    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    
    if object_id('dbo.MSsnapshotdeliveryprogress') is null
    begin
        create table dbo.MSsnapshotdeliveryprogress 
        (
           session_token nvarchar(260) not null,
           progress_token_hash int not null,
           progress_token nvarchar(500) not null,
           progress_timestamp datetime default getdate()
        )
        if @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end        
        create index ci_MSsnapshotdeliveryprogress_progress_token_hash 
            on dbo.MSsnapshotdeliveryprogress(progress_token_hash)
        if @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end        
        create index nci_MSsnapshotdeliveryprogress_session_token
            on dbo.MSsnapshotdeliveryprogress(session_token)
        if @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end        
        exec @retcode = dbo.sp_MS_marksystemobject 'dbo.MSsnapshotdeliveryprogress'
        if @retcode <> 0 or @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end        
    end 

    select @snapshot_progress_token_hash = sys.fn_repl32bitstringhash(@snapshot_progress_token)
    if @retcode <> 0 or @@ERROR <> 0
    begin 
        select @retcode = 1
        goto FAILURE
    end        

    if exists (select * from MSsnapshotdeliveryprogress 
                where progress_token_hash = @snapshot_progress_token_hash
                  and progress_token = @snapshot_progress_token
                  and session_token = @snapshot_session_token)
    begin
        update MSsnapshotdeliveryprogress
           set progress_timestamp = getdate()
         where progress_token = @snapshot_progress_token
           and session_token = @snapshot_session_token
        if @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end        
    end
    else
    begin
        insert MSsnapshotdeliveryprogress 
            values (
                @snapshot_session_token,
                @snapshot_progress_token_hash,
                @snapshot_progress_token, 
                default)
        if @@ERROR <> 0
        begin 
            select @retcode = 1
            goto FAILURE
        end                 
    end         
    if @@ERROR <> 0
    begin 
        select @retcode = 1
        goto FAILURE
    end        

FAILURE:
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSrecordsnapshotdeliveryprogress] TO [public] AS [dbo]
GO
