SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSregistersubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSregistersubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSregistersubscription]
	@replication_type [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@publisher_security_mode [int],
	@publisher_login [sysname],
	@publisher_password [nvarchar](524),
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_security_mode [int],
	@subscriber_login [sysname],
	@subscriber_password [nvarchar](524),
	@distributor [sysname],
	@distributor_security_mode [int],
	@distributor_login [sysname],
	@distributor_password [nvarchar](524),
	@subscription_id [uniqueidentifier],
	@independent_agent [int],
	@subscription_type [int],
	@use_interactive_resolver [int],
	@failover_mode [int],
	@use_web_sync [bit],
	@hostname [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /* MobileSync Support */
    declare @regkey                            nvarchar(1000)
    declare @subidstr                        nvarchar(38)
    declare @profile_name                     nvarchar(100)
    declare @retcode                        int

    select @retcode = 0
    -- Security check: Sysadmin and DBO only
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
    end

    set @regkey = sys.fn_replgetsubscriptionregkey(@publisher, @publisher_db, @publication, @subscriber, @subscriber_db)
    set @subidstr = '{' + convert ( nchar(36), @subscription_id) + '}'
    set @profile_name = N'Windows Synchronization Manager profile' -- SyncMgr Profile

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'ProfileName',
                               'REG_SZ',
                                @profile_name    
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'ReplicationType',
                               'REG_DWORD',
                                @replication_type    
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'SubscriptionType',
                               'REG_DWORD',
                                @subscription_type    
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'Subid',
                               'REG_SZ',
                                @subidstr    
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'Publisher',
                               'REG_SZ',
                                @publisher                                        
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'PublisherDb',
                               'REG_SZ',
                                @publisher_db
    if @retcode <> 0 OR @@ERROR <> 0
        return 1


    IF @use_interactive_resolver IS NOT NULL
    BEGIN
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'UseInteractiveResolver',
                               'REG_DWORD',
                                @use_interactive_resolver
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    END

    /* If Publisher security mode is NOT NULL, write out the entries */
    if @publisher_security_mode IS NOT NULL
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                                   @regkey,
                                   'PublisherSecurityMode',
                                   'REG_DWORD',
                                    @publisher_security_mode
        if @retcode <> 0 OR @@ERROR <> 0
            return 1

        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                                   @regkey,
                                   'PublisherLogin',
                                   'REG_SZ',
                                    @publisher_login                                    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1

    end
    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'Publication',
                               'REG_SZ',
                                @publication
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'Subscriber',
                               'REG_SZ',
                                @subscriber
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    /* If Subscriber security mode is NOT NULL, write out the entries */
    if @subscriber_security_mode IS NOT NULL
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'SubscriberSecurityMode',
                           'REG_DWORD',
                            @subscriber_security_mode
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
            
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'SubscriberLogin',
                           'REG_SZ',
                            @subscriber_login                                    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end

    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'SubscriberDb',
                               'REG_SZ',
                                @subscriber_db                                    
    if @retcode <> 0 OR @@ERROR <> 0
        return 1
                
    EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                               @regkey,
                               'Distributor',
                               'REG_SZ',
                                @distributor
    if @retcode <> 0 OR @@ERROR <> 0
        return 1

    /* If Distributor security mode is NOT NULL, write out the entries */
    if @distributor_security_mode IS NOT NULL
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'DistributorSecurityMode',
                           'REG_DWORD',
                            @distributor_security_mode
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
            
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'DistributorLogin',
                           'REG_SZ',
                            @distributor_login                                    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end

    if @independent_agent IS NOT NULL
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'IndependentAgent',
                           'REG_DWORD',
                            @independent_agent    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end

    IF @failover_mode IS NOT NULL
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'FailoverMode',
                           'REG_DWORD',
                            @failover_mode    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1

    end        
        
    IF @use_web_sync IS NOT NULL
    begin
        declare @use_web_sync_int int
        select @use_web_sync_int = convert(int, @use_web_sync)
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                           @regkey,
                           'WebSync',
                           'REG_DWORD',
                            @use_web_sync_int    
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end            

    if @hostname is not null
    begin
        EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                              @regkey,
                              'HostName',
                              'REG_SZ',
                               @hostname
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end

    -- Mark enabled_for_syncmgr bit if every thing succeeded.
    -- If the row exists in MSreplication_properties table, 
    -- set enabled_for_syncmgr bit
    -- The logic need to be here because UI call this sp directly.
    if object_id('MSsubscription_properties') is not NULL
    begin
        update MSsubscription_properties set enabled_for_syncmgr = 1 where
            UPPER(publisher) = UPPER(@publisher)
            and publisher_db =  @publisher_db
            and publication = @publication
        if @retcode <> 0 OR @@ERROR <> 0
            return 1
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSregistersubscription] TO [public] AS [dbo]
GO
