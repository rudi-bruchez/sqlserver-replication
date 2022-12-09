SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdateinitiallightweightsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdateinitiallightweightsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdateinitiallightweightsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication_name [sysname],
	@pubid [uniqueidentifier],
	@allow_subscription_copy [bit],
	@retention [int],
	@conflict_logging [int],
	@status [int],
	@allow_synctoalternate [bit],
	@replicate_ddl [int],
	@automatic_reinitialization_policy [bit]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @retcode int
	
	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1
	
    declare @pubid_local uniqueidentifier

    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    select @pubid_local = pubid from dbo.sysmergepublications 
        where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) and 
			  publisher_db = @publisher_db and 
			  name = @publication_name
    
	update dbo.sysmergepublications 
		set pubid=	@pubid, 
			retention= @retention,
			status= @status,
            centralized_conflicts= case @conflict_logging
                when 1 then 1
                when 2 then 1
                else 0
            end,
            decentralized_conflicts= case @conflict_logging
                when 1 then 0
                when 2 then 1
                else 1
            end,
			allow_subscription_copy= @allow_subscription_copy,
			allow_synctoalternate= @allow_synctoalternate,
			replicate_ddl= @replicate_ddl,
			automatic_reinitialization_policy= @automatic_reinitialization_policy
		where pubid = @pubid_local
	if @@error <> 0 return 1

    update dbo.sysmergesubscriptions set pubid= @pubid, replicastate= newid() where pubid = @pubid_local
	if @@error <> 0 return 1

    update dbo.sysmergesubscriptions set subid = @pubid where subid = @pubid_local
	if @@error <> 0 return 1
	
	update dbo.MSmerge_replinfo set repid = @pubid where repid = @pubid_local
	if @@error <> 0 return 1
	
	execute @retcode= sys.sp_MSrepl_ddl_triggers @type='merge', @mode='add'
	if @@error <> 0 or @retcode <> 0 return (1)
		
	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSupdateinitiallightweightsubscription] TO [public] AS [dbo]
GO
