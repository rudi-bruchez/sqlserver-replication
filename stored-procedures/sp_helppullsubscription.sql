SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helppullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helppullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helppullsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@show_push [nvarchar](5)
WITH EXECUTE AS CALLER
AS
begin
    SET NOCOUNT ON

    -- Declarations.
    DECLARE @command nvarchar(255)
                ,@name nvarchar(255)
                ,@retcode int
                ,@show_push_bit bit
                ,@push int
                ,@subscriber            sysname
                ,@subscriber_db        sysname
                ,@publisher_local    sysname
                ,@publisher_db_local    sysname
                ,@publication_local    sysname
                ,@subscription_name     nvarchar(1000)
                ,@regkey                nvarchar(1000)
                ,@syncmgr_keyexist                int
                ,@helpsubscriptioncursor_open    int

    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode <> 0 or @@error <> 0
        return 1

    -- For attach
    if object_id(N'dbo.MSrepl_restore_stage') is not null
        -- The database is attached from a subscription copy file without using
        -- sp_attachsubscription. Return nothing
        return 0
    --
    -- Initializations.
    --
    select @subscriber = @@SERVERNAME     
            ,@subscriber_db = DB_NAME()
            ,@push = 0
    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is define
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_helppullsubscription')
        RETURN (1)
    END

    IF @publisher <> N'%' 
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher
        IF @@ERROR <> 0 OR @retcode <> 0
               RETURN (1)
    END

    IF @publication <> N'%' 
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publication
        IF @@ERROR <> 0 OR @retcode <> 0
               RETURN (1)
    END

    IF @show_push IS NOT NULL AND 
        LOWER(@show_push) NOT IN (N'true', N'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@show_push')
        RETURN (1)
    END
    SELECT @show_push_bit = case when (LOWER(@show_push) = N'false') then 0 else 1 end

    IF object_id('MSreplication_subscriptions','U') is NULL 
                OR object_id('MSsubscription_properties','U') is NULL
                OR object_id('MSsubscription_agents','U') is NULL
        RETURN (0)                
    /*
    ** Get the result
    ** Note: have to return meta data
    */
    SELECT  'publisher'                = rs.publisher,
        'publisher database'    = rs.publisher_db,
        'publication'            = rs.publication,
        'independent_agent'        = rs.independent_agent,
        'subscription type'     = rs.subscription_type,
        'distribution agent'    = distribution_agent,
        'publication description'   = rs.description,
        'last updating time'        = sys.fn_replformatdatetime(time),
        'subscription_name'          = rs.publisher + N':' + rs.publisher_db + N':' + rs.publication,
        'last transaction timestamp' = transaction_timestamp,
        -- SyncTran
        -- For Queued case, Until the subscription is initialized
        -- the entry in MSreplication_subscriptions will be used to
        -- decide the update mode. Once the distribution agent has 
        -- initialized the entry in MSsubscription_agents, then we
        -- will use failover_mode instead (the update mode entry in 
        -- MSreplication_subscriptions will be changed by distribution
        -- agent) 
        -- 
        -- When update mode = 6 - Queued Failover (4)
        -- When update mode = 4 - Queued only (2)
        -- When update mode = 5 and Failover flag = 0 - Immediate Failover (3)
        -- When update mode = 5 and Failover flag = 1 - Queued Failover (4)
        --
        'update_mode'         = case     
                        when rs.update_mode = 4 then 2
                        when rs.update_mode = 6 then 4
                        when rs.update_mode = 5 and isnull(a.failover_mode,0) = 0 then 3
                        when rs.update_mode = 5 and isnull(a.failover_mode,0) = 1 then 4
                        else rs.update_mode
                end,
        'distribution agent job_id' = agent_id,
        'enabled for syncmgr' = enabled_for_syncmgr,
        'subscription guid' = subscription_guid,
        'subid ' = subid,
        'immediate_sync' = immediate_sync,
        'publisher_login' = publisher_login,
        'publisher_password' = publisher_password,
        'publisher_security_mode' = publisher_security_mode,
        'distributor' = distributor,
        'distributor_login' = distributor_login,
        'distributor_password' = distributor_password,
        'distributor_security_mode' = distributor_security_mode,
        'ftp_address' = ftp_address,
        'ftp_port' = ftp_port,
        'ftp_login' = ftp_login,
        'ftp_password' = ftp_password,
        'alt_snapshot_folder' = alt_snapshot_folder,
        'working_directory' = working_directory,
        'use_ftp' = use_ftp,
        'publication_type' = publication_type,
        'dts_package_name' = dts_package_name,
        'dts_package_location' = dts_package_location,
        'offload_agent' = offload_agent,
        'offload_server' = offload_server,
        a.last_sync_status, 
        a.last_sync_summary,
        'last_sync_time' = sys.fn_replformatdatetime(a.last_sync_time),
        'job_login' = sc.credential_identity,
        'job_password' = N'**********'
    from MSreplication_subscriptions rs
        left outer join MSsubscription_properties sp 
            on (UPPER(rs.publisher) = UPPER(sp.publisher) and rs.publisher_db = sp.publisher_db and rs.publication = sp.publication) 
        left outer join MSsubscription_agents a
            on (UPPER(rs.publisher) = UPPER(a.publisher) and 
                rs.publisher_db = a.publisher_db and 
                ((rs.publication = a.publication and 
                rs.independent_agent = 1 and
                a.publication <> N'ALL') or
                (a.publication = N'ALL' and rs.independent_agent = 0)) and
                rs.subscription_type = a.subscription_type)
        left outer join msdb..sysjobsteps sj
            on sp.job_step_uid = sj.step_uid
        left outer join msdb..sysproxies p
            on sj.proxy_id = p.proxy_id
        left join sys.credentials sc
            on p.credential_id = sc.credential_id
    where ((@publisher = N'%') OR (UPPER(rs.publisher) = UPPER(@publisher))) AND
        ((@publisher_db = N'%') OR (rs.publisher_db = @publisher_db)) AND
        ((@publication = N'ALL' AND rs.independent_agent = 0) OR rs.publication LIKE @publication) AND
        (rs.subscription_type <> @push OR
        @show_push_bit = 1)
    ORDER BY rs.publisher, rs.publisher_db, rs.publication
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_helppullsubscription] TO [public] AS [dbo]
GO
