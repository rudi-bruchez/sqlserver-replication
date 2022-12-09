SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addpublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addpublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addpublication]
	@publication [sysname],
	@taskid [int],
	@restricted [nvarchar](10),
	@sync_method [nvarchar](40),
	@repl_freq [nvarchar](10),
	@description [nvarchar](255),
	@status [nvarchar](8),
	@independent_agent [nvarchar](5),
	@immediate_sync [nvarchar](5),
	@enabled_for_internet [nvarchar](5),
	@allow_push [nvarchar](5),
	@allow_pull [nvarchar](5),
	@allow_anonymous [nvarchar](5),
	@allow_sync_tran [nvarchar](5),
	@autogen_sync_procs [nvarchar](5),
	@retention [int],
	@allow_queued_tran [nvarchar](5),
	@snapshot_in_defaultfolder [nvarchar](5),
	@alt_snapshot_folder [nvarchar](255),
	@pre_snapshot_script [nvarchar](255),
	@post_snapshot_script [nvarchar](255),
	@compress_snapshot [nvarchar](5),
	@ftp_address [sysname],
	@ftp_port [int],
	@ftp_subdirectory [nvarchar](255),
	@ftp_login [sysname],
	@ftp_password [sysname],
	@allow_dts [nvarchar](5),
	@allow_subscription_copy [nvarchar](5),
	@conflict_policy [nvarchar](100),
	@centralized_conflicts [nvarchar](5),
	@conflict_retention [int],
	@queue_type [nvarchar](10),
	@add_to_active_directory [nvarchar](10),
	@logreader_job_name [sysname],
	@qreader_job_name [sysname],
	@publisher [sysname],
	@allow_initialize_from_backup [nvarchar](5),
	@replicate_ddl [int],
	@enabled_for_p2p [nvarchar](5),
	@publish_local_changes_only [nvarchar](5),
	@enabled_for_het_sub [nvarchar](5),
	@p2p_conflictdetection [nvarchar](5),
	@p2p_originator_id [int],
	@p2p_continue_onconflict [nvarchar](5),
	@allow_partition_switch [nvarchar](5),
	@replicate_partition_switch [nvarchar](5),
	@allow_drop [nvarchar](5)
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    DECLARE @cmd  nvarchar(4000)
                ,@retcode  int
                ,@publisher_type sysname

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo @publisher = @publisher,
                                                                        @publisher_type = @publisher_type OUTPUT,
                                                                        @rpcheader = @cmd OUTPUT
    IF @retcode != 0 or @@error !=0
        RETURN 1

    -- Add sp
    select @publisher = UPPER(@publisher) 
            ,@cmd = @cmd + N'sys.sp_MSrepl_addpublication'

    EXEC @retcode = @cmd
                            @publication,
                            @taskid,
                            @restricted,
                            @sync_method,
                            @repl_freq,
                            @description,
                            @status,
                            @independent_agent,
                            @immediate_sync,
                            @enabled_for_internet,
                            @allow_push,
                            @allow_pull,
                            @allow_anonymous,
                            @allow_sync_tran,
                            @autogen_sync_procs,
                            @retention,
                            @allow_queued_tran,
                            @snapshot_in_defaultfolder,
                            @alt_snapshot_folder,
                            @pre_snapshot_script,
                            @post_snapshot_script,
                            @compress_snapshot,
                            @ftp_address,
                            @ftp_port,
                            @ftp_subdirectory,
                            @ftp_login,
                            @ftp_password,
                            @allow_dts,
                            @allow_subscription_copy,
                            @conflict_policy,
                            @centralized_conflicts,
                            @conflict_retention,
                            @queue_type,
                            @add_to_active_directory,
                            @logreader_job_name,
                            @qreader_job_name,
                            @publisher,
                            @allow_initialize_from_backup,
                            @replicate_ddl,
                            @publisher_type,
                            @enabled_for_p2p,
                            @publish_local_changes_only,
                            @enabled_for_het_sub,
                            @p2p_conflictdetection,
                            @p2p_originator_id,
                            @p2p_continue_onconflict,
							@allow_partition_switch,
							@replicate_partition_switch,
							@allow_drop

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addpublication] TO [public] AS [dbo]
GO
