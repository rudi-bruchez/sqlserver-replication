SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MStran_is_snapshot_required]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MStran_is_snapshot_required] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MStran_is_snapshot_required]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [int],
	@run_at_distributor [bit],
	@last_xact_seqno [varbinary](16),
	@subscription_guid [varbinary](16),
	@subid [varbinary](16)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    
    -- constants
    declare @INACTIVE         tinyint
    declare @SUBSCRIBED        tinyint
    declare @ACTIVE         tinyint
    declare @INITIATE         tinyint
    declare @PUSH            tinyint    
    declare @PULL            tinyint
    declare @ANONYMOUS        tinyint    
    declare @SYNC_TYPE_NONE tinyint
    declare @NOT_NEEDED        tinyint
    declare @NEEDED            tinyint
    declare @UNKNOWN        tinyint
    declare @TRAN_PUB        tinyint
    declare @SNAPSHOT_PUB    tinyint
    declare @SNAPSHOT_BIT     varbinary(16)
    declare @SYNCTRAN_TYPE     int
    declare @READ_ONLY        tinyint
    declare @CONCURRENT     tinyint
    declare @CONCURRENT_C     tinyint
    
    -- local vars
    declare @retcode                 int
    declare @publisher_name            sysname
    declare @publisher_database_id    int
    declare @pub_type                int
    declare @sub_count                int
    declare @pub_id                    int
    declare @agent_id                int
    declare @publication_id            int
    declare @sync_type                int
    declare @allow_anon                bit
    declare @immediate_sync            bit
    declare @status                    int
    declare @transaction_timestamp    varbinary(16)
    declare @dist_sub_guid            varbinary(16)
    declare @max_xact_seqno            varbinary(16)
    declare    @num_non_active            int
    declare @max_sub_seqno             varbinary(16)
    declare @min_sub_seqno             varbinary(16)
    declare @max_pub_seqno          varbinary(16)
    declare @is_needed                int        -- flag to be selected prior to exit
                                            -- 0 not needed 1 needed 2 unknown
    select @INACTIVE        = 0
    select @SUBSCRIBED        = 1
    select @ACTIVE            = 2
    select @INITIATE        = 3
    select @PUSH            = 0
    select @PULL            = 1
    select @ANONYMOUS        = 2
    select @SYNC_TYPE_NONE     = 2
    select @NOT_NEEDED        = 0
    select @NEEDED            = 1
    select @UNKNOWN            = 2
    select @TRAN_PUB        = 0
    select @SNAPSHOT_PUB    = 1
    select @SNAPSHOT_BIT    = 0x80000000
    select @SYNCTRAN_TYPE      = @SNAPSHOT_BIT | 9
    select @READ_ONLY        = 0
    select @CONCURRENT      = 3
    select @CONCURRENT_C      = 4
    
    select @retcode                 = 0
    select @publisher_name            = null
    select @publisher_database_id    = null
    select @pub_type                = null
    select @sub_count                = 0
    select @pub_id                    = null
    select @agent_id                = null
    select @publication_id            = null
    select @sync_type                = null 
    select @allow_anon                = 0
    select @immediate_sync            = null
    select @status                    = null
    select @transaction_timestamp    = null
    select @dist_sub_guid            = null
    select @max_xact_seqno            = null
    select @num_non_active            = 0
    select @max_sub_seqno             = 0x00
    select @min_sub_seqno            = 0x00
    select @max_pub_seqno              = 0x00
    select @is_needed                = @UNKNOWN

    -- Security check: db_owner, sysadmin if proc is called at the subscriber;
    -- PAL at the distributor

    if @run_at_distributor = 0
    begin
        exec @retcode = sys.sp_MSreplcheck_subscribe    
        if @@error<>0 or @retcode<>0
        begin
            return 1
        end
    end

    -- Common Parameter Validation
    if @publisher is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publisher', 'sp_MStran_is_snapshot_required')
        return (1)
    end

    if @publisher_db is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publisher_db', 'sp_MStran_is_snapshot_required')
        return (1)
    end
    
    if @publication is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publication', 'sp_MStran_is_snapshot_required')
        return (1)
    end

    if @subscription_type not in (@PUSH, @PULL, @ANONYMOUS)
    begin
        raiserror(20587, 16, -1, @subscription_type, 'sp_MStran_is_snapshot_required')
        return (1)
    end

    -- Perform subscriber side queries
    if @run_at_distributor = 0
    begin
        -- push cases do not have this table. instead of checking for push we will just check if the table 
        -- exists then retrieve the publication type. We can use this for one special case, SNAPSHOT PUBS.
        if object_id ('MSsubscription_properties') is not null
        begin
            select @pub_type = publication_type
                from dbo.MSsubscription_properties mssp
                where mssp.publisher         = @publisher
                    and mssp.publisher_db    = @publisher_db
                    and mssp.publication     = @publication
        end

        -- check for table
        if object_id ('MSreplication_subscriptions') is not null
        begin
            -- Retrieve time stamp and publication information
            select     @publisher_name = msrs.publisher,
                    @transaction_timestamp = msrs.transaction_timestamp,
                    @subscription_guid = msrs.subscription_guid,
                    @subid = msrs.subid
                from dbo.MSreplication_subscriptions msrs                    
                where msrs.publisher             = @publisher
                        and msrs.publisher_db     = @publisher_db
                        and (msrs.publication     = @publication
                                or (msrs.publication             = ''     -- this 'or' case is here for subs on pubs with NON-independednt agents
                                    and @pub_type                 = NULL
                                    and msrs.independent_agent     = 0))
                        and msrs.subscription_type     = @subscription_type
        end
        else
        begin
            select @publisher_name = null
        end 
        
        -- check for valid publisher name
        if @publisher_name is null
        begin
            -- if the subscription is push and the table does not exist it could mean 1 of two things. 
            -- 1-Snapshot not applied yet or 2-Subscription not found. Either will mean unknown for push.
            -- We can not say sub not found because what if the distributor knows about the sub (case 1).
            -- or
            -- If it is push then it is also possible that the table exists but the subscriber
            -- has not sync'd or failed durring a sync and has the table but no entries.
            if @subscription_type = @PUSH
            begin
                -- set the @subscription_guid to 0x00 which indicate that the tables 
                -- did not exist when the proc was called at the subscriber side
                select @transaction_timestamp     = 0x00
                select @subscription_guid         = 0x00
                select @subid                    = 0x00
    
                -- set to unknown and then return
                select @is_needed = @UNKNOWN
                goto Results_Handler
            end

            -- for any other case (PULL + ANON) this means...
            -- The subscription on the Subscriber does not exist.
            raiserror (20017, 16, -1)
            return (1)
        end

        -- Take a look at the time stamp and subscription_guid to see if a snapshot is needed. On reinit 
        -- or initial subscription creation the tran_timestamp is set to 0x00 and subscription_guid is set
        -- to null. When these cases are met we can assume this means that the snapshot must be applied.
        -- or
        -- For anon subscriber side reinit case only the timestamp is reset so we need to check for this case
        -- or
        -- check to see if this is a snapshot publication. if so utomatically return @NEEDED since snapshot
        -- pubs will always need to retrieve a new snapshot from the publisher side.
        if (@transaction_timestamp = 0x00 and @subscription_guid is NULL) 
            or (@subscription_type  = @ANONYMOUS and @transaction_timestamp = 0x00 and @subscription_guid is not NULL) 
            or @pub_type = @SNAPSHOT_PUB
        begin
            select @is_needed = @NEEDED
        end
        -- Any push case should be checked at the distributor side as well for further info
        -- but according to the information at the subscriber no snapshot is currently needed
        -- and
        -- for pull and anon case where the time stamp is not 0x00 then we do not need a snapshot
        else if @transaction_timestamp <> 0x00
        begin
            select @is_needed = @NOT_NEEDED
        end
        -- any other case will be set to unknown since they are not handled and will have to be checked at distributor
        else
        begin
            select @is_needed = @UNKNOWN
        end

        goto Results_Handler
    end
    -- Perform distributor side queries
    else
    begin
        if object_id('MSpublications') is null
        begin
            -- Must be run on distributor.
            raiserror(21454, 16, -1)
            return (1)
        end
        
        -- retrieve publication id etc.
        select @pub_id = msp.publisher_id,
                @pub_type = msp.publication_type,
                @publication_id = msp.publication_id,
                @allow_anon = msp.allow_anonymous,
                @immediate_sync = msp.immediate_sync
            from dbo.MSpublications msp,
                    MSreplservers sv
            where sv.srvname          = @publisher
                    and msp.publisher_id     = sv.srvid
                    and (msp.publication     = @publication
                     or (@publication is null or @publication = N'' or upper(@publication) = N'ALL') and msp.independent_agent = 0)
                    and msp.publisher_db     = @publisher_db
                    and msp.publication_type in (@TRAN_PUB, @SNAPSHOT_PUB)

        -- check for valid pubid
        if @pub_id is null
        begin
            -- The publication '%s' does not exist.
            raiserror(20026, 16, -1, @publication)
            return (1)
        end

        -- Distributor side specific parameter validation
        
        -- if the subscription is anon and we do not allow it then we know we can't find it
        if @subscription_type = @ANONYMOUS and @allow_anon = 0
        begin
            -- The subscription could not be found.
            raiserror(20021, 16, -1)
            return (1)
        end
        
        -- if the subscription is anon and guids/ids are null then we are not sure 
        -- because it could be the subscription was created but never initialized
        if @subscription_type = @ANONYMOUS and @subscription_guid is null and @subid is null
        begin
            select @is_needed = @UNKNOWN
            goto Results_Handler
        end

        -- if it's an immediate sync publication then we will require the subscription guid 
        if @immediate_sync = 1 and @subscription_guid is null
        begin
            -- The parameter %s cannot be NULL.
            raiserror (14043, 16, -1, '@subscription_guid', 'sp_MStran_is_snapshot_required')
            return (1)
        end

        if @subscriber is null
        begin
            -- The parameter %s cannot be NULL.
            raiserror (14043, 16, -1, '@subscriber', 'sp_MStran_is_snapshot_required')
            return (1)
        end

        if @subscriber_db is null
        begin
            -- The parameter %s cannot be NULL.
            raiserror (14043, 16, -1, '@subscriber_db', 'sp_MStran_is_snapshot_required')
            return (1)
        end

        -- set last seqno if it was passed in as null
        if @last_xact_seqno is null 
        begin
            select @last_xact_seqno = 0x00
        end

        -- if it is a pull or push and publication is not immediate then attempt
        -- to retrieve the information from MSsubscriptions status column which is
        -- only a valid value for the pull/push non-immediate_sync cases
        -- 
        -- we also skip over pub_type = SNAP_PUB because we have an optimization for
        -- it following this check.
        --
        -- NOTE:
        -- If the result of this does not hit the snapshot is NEEDED section then
        -- we will follow this with more system table checks to ensure we have
        -- the correct value. This is just to avoid extra processing if possible
        if @subscription_type in (@PULL, @PUSH) and @immediate_sync = 0 and @pub_type <> @SNAPSHOT_PUB
        begin  
            -- Attempt to retrieve information for well known subscriptions
            select @status = min(mss.status),
                    @sub_count = count(mss.status),
                    @sync_type = max(mss.sync_type)
                from dbo.MSsubscriptions mss,
                        MSreplservers sv
                where sv.srvname               = @subscriber
                        and mss.subscriber_id         = sv.srvid
                        and mss.subscriber_db         = @subscriber_db
                        and mss.publisher_id         = @pub_id
                        and mss.publisher_db         = @publisher_db
                        and mss.publication_id         = @publication_id
                        and mss.subscription_type     = @subscription_type

            -- subcount is > 0 and status is not null
            if @sub_count = 0 or @status is null 
            begin
                -- The subscription could not be found.
                raiserror(20021, 16, -1)
                return (1)
            end
            
            -- nosync subscriptions will never be reinitialized and never need a snapshot
            if @sync_type = @SYNC_TYPE_NONE
            begin
                select @is_needed = @NOT_NEEDED
                goto Results_Handler
            end

            -- any status that is inactive or subscribed will need the snapshot
            -- also
            -- if this is a snapshot publication automatically return @NEEDED since 
            -- snapshot pubs will always retrieve a snapshot from the publisher side
            if @status in (@INACTIVE, @SUBSCRIBED) or @pub_type = @SNAPSHOT_PUB
            begin
                select @is_needed = @NEEDED
                goto Results_Handler
            end
        end

        -- For the push pull case retrieve the value from dist agent            
        if @subscription_type in (@PULL, @PUSH)
        begin
            select @publisher_database_id = msda.publisher_database_id,
                    @dist_sub_guid = msda.subscription_guid,
                    @agent_id = msda.id
                from dbo.MSdistribution_agents msda,
                    MSreplservers sv
                where sv.srvname = @subscriber
                    and msda.subscriber_id         = sv.srvid
                    and msda.subscriber_db         = @subscriber_db
                    and msda.publisher_id         = @pub_id
                    and msda.publisher_db         = @publisher_db
                    and msda.publication         in  (@publication, N'ALL')
                    and msda.subscription_type     = @subscription_type
        end
        -- for anon use the virtual_agent_id to retrieve the value
        else if @subscription_type = @ANONYMOUS
        begin
            -- if the last tran sequence number is 0x00 then use virtual id to grab the actual agent id
            -- if not then we should be using the anonymous_agent_id (see sp_MSget_repl_cmds_anonymous)
            if @last_xact_seqno = 0x00
            begin
                select @publisher_database_id = msda2.publisher_database_id,
                        @dist_sub_guid = msda2.subscription_guid,
                        @agent_id = msda2.id
                    from dbo.MSdistribution_agents msda1,
                            dbo.MSdistribution_agents msda2
                    where msda1.subscription_guid = @subid
                            and msda2.id = msda1.virtual_agent_id
            end
            else
            begin
                select @publisher_database_id = msda2.publisher_database_id,
                        @dist_sub_guid = msda2.subscription_guid,
                        @agent_id = msda2.id
                    from dbo.MSdistribution_agents msda1,
                            dbo.MSdistribution_agents msda2
                    where msda1.subscription_guid = @subid
                            and msda2.id = msda1.anonymous_agent_id
            end
        end
        -- if for whatever reason we have another subscription type 
        -- (this should never actually happen) let's set the vals to null
        else
        begin
            select @publisher_database_id     = null
            select @dist_sub_guid             = null
            select @agent_id                = null
        end
        
        -- make sure values are valid
        if @publisher_database_id is null or @agent_id is null or @dist_sub_guid is null
        begin
            -- The subscription could not be found.
            raiserror(20021, 16, -1)
            return (1)
        end

        -- By now, we should be in "a" distribution database so regardless
        -- of whether the distribution database procedure sp_MScheck_pull_access
        -- has been moved into the resource database.
        exec @retcode = sys.sp_MScheck_pull_access
            @agent_id = @agent_id,
            @agent_type = 0 -- distribution agent
        if @@error <> 0 or @retcode <> 0
            return (1)

        -- now that we know the subscription exists let's check to see if 
        -- it is a snap pub. if so snap pubs always need a new snapshot.
        if @pub_type = @SNAPSHOT_PUB
        begin
            select @is_needed = @NEEDED
            goto Results_Handler
        end

        -- retrieve sync type
        select @sync_type = max(sync_type)
            from dbo.MSsubscriptions
            where agent_id = @agent_id

        -- nosync subscriptions will never be reinitialized and never need a snapshot
        if @sync_type = @SYNC_TYPE_NONE
        begin
            select @is_needed = @NOT_NEEDED
            goto Results_Handler
        end

        -- if this agent is servicing any inactive concurrent sync articles then say
        -- no snapshot needed.  The concurrent sync article will be activated when the 
        -- SYNCDONE token is written to the distribution db by the logreader at this 
        -- point, all log records associated with the sync will be present in MSrepl_commands
        -- (see sp_MSget_repl_commands for more details)
        if exists(select * 
                    from MSsubscriptions s 
                        join MSpublications p 
                       on (s.publisher_id = p.publisher_id
                         and s.publisher_db = p.publisher_db
                         and s.publication_id = p.publication_id)
                    where s.agent_id = @agent_id
                         and s.status = @INITIATE
                         and (p.sync_method = @CONCURRENT 
                                 or p.sync_method = @CONCURRENT_C))
        begin
               select @is_needed = @NOT_NEEDED
            goto Results_Handler
        end
        
        -- if it is anonymous and the @subid is 0x00 then that means that the subscription has 
        -- just been created but has never been initialized. Unfortunately we have no way of
        -- knowing unless that snapshot is applied or we query the subscriber side again.
        if @subscription_type = @ANONYMOUS and @subid = 0x00
        begin
            select @is_needed = @UNKNOWN
            goto Results_Handler
        end
        -- for push and pull if the guids are equal at the sub and dist then we will most 
        -- likly have to check the replcommands table for the snapshot app needed info. We 
        -- say most likely because there are some optimizations inside to avoid hitting
        -- replcommands if at all possible.
        --
        -- in the anonymous case, if we are here we will always need to come in and
        -- perform extra checks because the subscription guid for anon is not reliable
        else if @dist_sub_guid = @subscription_guid or @subscription_type = @ANONYMOUS
        begin
            -- retrieve some info to check if we are done with snapshot transactions        
            select @num_non_active = sum(case when status <> @ACTIVE then 1 else 0 end),
                    @max_sub_seqno = max(subscription_seqno),
                    @min_sub_seqno = min(subscription_seqno),
                    @max_pub_seqno = max(publisher_seqno)
                from MSsubscriptions 
                where agent_id = @agent_id

            -- if there are any non-active subscriptions then need a snapshot
            if @num_non_active > 0
            begin
                select @is_needed = @NEEDED
                goto Results_Handler
            end
            
            -- if these conditions are met then we know we do not need a snapshot and can exit
            if  @last_xact_seqno > @max_sub_seqno and  
                @last_xact_seqno > @max_pub_seqno
            begin
                select @is_needed = @NOT_NEEDED
                goto Results_Handler
            end
            
            -- Get the last xact_seqno on the pub db FIRST. It will
            -- be used as the upper bound for differnt queries. We have to do
            -- this to prevent transactions on new or changed subscriptions or
            -- with new orignator_id being skipped eigher by preselected query or
            -- preselected originator_id.
            -- Have to have readpast here to prevent the query be blocked by logreader
            -- (even before the first row to the dist agent).
            --
            -- Note:  DO NOT consider distcmds inserted for a concurrent snapshot
            -- These represent 'forward in time' xacts.  Skipping past these xacts
            -- can cause lost transactions!
            --
            -- Note2: consider adding new MSrepl_commands idx with keys:  
            -- publisher_database_id, command_id, type, xact_seqno
            --
            -- Note3: might be able to use replpostcmd + a LSN mapping token to 
            -- allow SS agent to post sync cmds to log instead of dist db.
            --
            select @max_xact_seqno = max(xact_seqno) 
                from MSrepl_commands with (READPAST)
                where publisher_database_id = @publisher_database_id 
                        and command_id         = 1 
                        and type             <> -2147483611
            
            -- If there's nothing to do set not needed and move on to results
            if @max_xact_seqno = @last_xact_seqno
            begin
                select @is_needed = @NOT_NEEDED
                goto Results_Handler
            end
            
            -- check MSrepl_commands to see if we have snapshot commands waiting for us
            -- Consider:
            -- We may want to use a use a dirty read since if the snapshot is generating/logreader is
            -- is picking up snap commands we can make our assumptions that the snapshot is needed.
            -- for this assumption to be true it doesn't matter if anything by the logreader is 
            -- rolled back because of an error etc. We will still need a snapshot later.
            if exists (select msrc.*
                            from MSrepl_commands msrc, 
                                    MSsubscriptions mss
                            where mss.agent_id                         = @agent_id 
                                    and mss.status                     = @ACTIVE                    -- make sure only to scan the active subs
                                    and mss.publisher_database_id     = @publisher_database_id 
                                    and msrc.publisher_database_id     = mss.publisher_database_id
                                    and msrc.article_id             = mss.article_id             
                                    and msrc.xact_seqno             > @last_xact_seqno             -- lower bound
                                    and msrc.xact_seqno             >= @min_sub_seqno            --         this is here in case @last_xact_seqno is 0x00
                                    and msrc.xact_seqno             <= @max_xact_seqno            -- upper bound
                                    and (msrc.type & @SNAPSHOT_BIT)    = @SNAPSHOT_BIT                -- make sure they are snapshot commands
                                    -- 1. filter out the  snapshot transactions that were inserted later that is not
                                    --    the subscription's snapshot transaction
                                    -- 2. filter out trigger generation command for non synctran subscription.
                                    and ( (msrc.type & @SNAPSHOT_BIT)    = @SNAPSHOT_BIT 
                                            and msrc.xact_seqno         >= mss.subscription_seqno 
                                            and msrc.xact_seqno         <= mss.ss_cplt_seqno 
                                            and ( msrc.type             <> @SYNCTRAN_TYPE 
                                                    or mss.update_mode     <> @READ_ONLY ) ))

            begin
                select @is_needed = @NEEDED
            end
            else
            begin
                select @is_needed = @NOT_NEEDED
            end

            goto Results_Handler
        end
        else
        begin
            -- all else needs a snapshot
            select @is_needed = @NEEDED

            goto Results_Handler
        end
    end

Results_Handler:
    select "is_snapshot_required" = @is_needed,
            "last_xact_seqno"    = @transaction_timestamp,
            "subscription_guid"    = @subscription_guid,
            "subid"             = @subid

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MStran_is_snapshot_required] TO [public] AS [dbo]
GO
