SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_snapshot_helppublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_snapshot_helppublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_snapshot_helppublication]
	@publication [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    /*
    ** Declarations.
    */

    DECLARE @pubid				int
    DECLARE @has_subscription	bit
    DECLARE @retcode			int
    DECLARE @publish_bit		int
    
    SELECT @publish_bit = 1

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)
    

    -- Parameter Check:  @publisher
	IF @publisher IS NULL
	BEGIN
		RAISERROR (14043, 16, -1, '@publisher', 'sp_MSrepl_snapshot_helppublication')
		RETURN (1)
	END

    -- Parameter Check:  @publication
    IF @publication IS NULL
	BEGIN
		RAISERROR (14043, 16, -1, '@publication', 'sp_MSrepl_snapshot_helppublication')
		RETURN (1)
	END
    
	EXECUTE @retcode = dbo.sp_validname @publication
	IF @retcode <> 0
		RETURN (1)
	
	SELECT	'pubid'						= sp.pubid,
			'name'						= sp.name,
			'restricted'				= 0,
			'status'					= sp.status,
			-- using 'task' is for backward compatibilty
			'task'						= convert(int, 1),
			'replication frequency'		= sp.repl_freq,
			'synchronization method'	= sp.sync_method,
			'description'				= sp.description,
			'immediate_sync'			= sp.immediate_sync,
			'enabled_for_internet'		= sp.enabled_for_internet,
			'allow_push'				= sp.allow_push,
			'allow_pull'				= sp.allow_pull,
			'allow_anonymous'			= sp.allow_anonymous,
			'independent_agent'			= sp.independent_agent,
			'immediate_sync_ready'		= sp.immediate_sync_ready,
			-- SyncTran
			'allow_sync_tran'			= sp.allow_sync_tran,
			'autogen_sync_procs'		= sp.autogen_sync_procs,
			'snapshot_jobid'			= sp.snapshot_jobid,
			'retention'					= sp.retention,
			'has subscription'			= CASE WHEN EXISTS
											(
												SELECT	*
												FROM	IHsubscriptions
												WHERE	article_id IN 
            									(
            										SELECT	article_id
            										FROM	IHarticles
            										WHERE	publication_id = sp.pubid
            									)
            								)
											THEN 1 ELSE 0 END,
			'allow_queued_tran'			= sp.allow_queued_tran,
			-- Portable snapshot
			'snapshot_in_defaultfolder'	= sp.snapshot_in_defaultfolder,
			'alt_snapshot_folder'		= sp.alt_snapshot_folder,
			-- Pre/post-snapshot commands
			'pre_snapshot_script'		= sp.pre_snapshot_script,
			'post_snapshot_script'		= sp.post_snapshot_script,
			-- Snapshot compression
			'compress_snapshot'			= sp.compress_snapshot,
			-- Post 7.0 ftp support
			'ftp_address'				= sp.ftp_address,
			'ftp_port'					= sp.ftp_port,
			'ftp_subdirectory'			= sp.ftp_subdirectory,
			'ftp_login'					= sp.ftp_login,
			'ftp_password'				= sys.fn_repldecryptver4(sp.ftp_password),
			'allow_dts'					= sp.allow_dts,
			'allow_subscription_copy'	= sp.allow_subscription_copy,
			-- 7.5 Queued updates
			'centralized_conflicts'		= NULL, 
			'conflict_retention'		= 14, 
			'conflict_policy'			= NULL,
			'queue_type'				= NULL,
			'backward_comp_level'		= sp.backward_comp_level,
			'publish_to_AD'				= CASE
											WHEN sp.ad_guidname IS NULL
											THEN 0 ELSE 1 END
	FROM	syspublications		sp,
			MSpublications		msp,
			MSreplservers	ss
	WHERE	sp.pubid = msp.publication_id
	AND		msp.publisher_id = ss.srvid
	AND     UPPER(ss.srvname collate database_default) = UPPER(@publisher) collate database_default
	AND		((sp.name = @publication) or  (@publication = N'%'))
	ORDER BY sp.name
	IF @@ERROR <> 0 RETURN 1
	
    RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_snapshot_helppublication] TO [public] AS [dbo]
GO
