SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSacquiresnapshotdeliverysessionlock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSacquiresnapshotdeliverysessionlock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSacquiresnapshotdeliverysessionlock]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @resource nvarchar(255)
    select @retcode = 0    
    select @resource = N'snapshot_delivery_in_progress_' + 
                       db_name() collate database_default
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    
    -- Try to create the snapshot delivery progress table here so multiple
    -- bcp threads in DTS snapshot are guaranteed to be able to access
    -- the snapshot progress table
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

    exec @retcode = sys.sp_getapplock @Resource = @resource,
                                             @LockMode = 'Shared',    
                                             @LockOwner = 'Session',
                                             @LockTimeout = -1,
                                             @DbPrincipal = N'db_owner'
    if @@error <> 0 or @retcode < 0
    begin
        select @retcode = 1
        goto FAILURE
    end
    select @retcode = 0
FAILURE:
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSacquiresnapshotdeliverysessionlock] TO [public] AS [dbo]
GO
