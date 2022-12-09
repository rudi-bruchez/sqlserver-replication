SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validatemergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validatemergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validatemergepullsubscription]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@level [tinyint]
WITH EXECUTE AS CALLER
AS
set nocount on 
    declare @retcode                int
    declare @pubid                    uniqueidentifier
    declare @subscriber                sysname
    declare @subscriber_db            sysname
    declare @subid                  uniqueidentifier
    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    select @subscriber = @@SERVERNAME, @subscriber_db=db_name()
    select @pubid = NULL
    select @subid = NULL
    
    select @pubid=pubid from dbo.sysmergepublications where LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db and name=@publication
    if @pubid is NULL
    begin
        raiserror (20026, 16, -1, @publication)
        return (1)
    end
    
    if @level <0 or @level > 3
    begin
        raiserror(21184, 16, -1, '@level', '1', '2','3')
        return (1)
    end

    select @subid = subid from dbo.sysmergesubscriptions where pubid=@pubid and db_name=@subscriber_db and LOWER(subscriber_server) = LOWER(@subscriber)
    if @subid is NULL
    begin
        raiserror(14055, 16, -1)
        return (1)
    end

    update dbo.MSmerge_replinfo 
        set validation_level=@level 
        where repid = @subid
    if @@ERROR<>0
        return (1)
    return (0)

GO
GRANT EXECUTE ON [sys].[sp_validatemergepullsubscription] TO [public] AS [dbo]
GO
