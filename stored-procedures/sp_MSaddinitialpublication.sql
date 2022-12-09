SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddinitialpublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddinitialpublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddinitialpublication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@description [nvarchar](255),
	@pubid [uniqueidentifier],
	@retention [int],
	@sync_mode [int],
	@allow_push [int],
	@allow_pull [int],
	@allow_anonymous [int],
	@conflict_logging [int],
	@status [int],
	@snapshot_ready [int],
	@enabled_for_internet [int],
	@publication_type [int],
	@conflict_retention [int],
	@allow_subscription_copy [int],
	@allow_synctoalternate [int],
	@backward_comp_level [int],
	@replicate_ddl [int],
	@retention_period_unit [tinyint],
	@replnickname [binary](6),
	@generation_leveling_threshold [int],
	@automatic_reinitialization_policy [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
    declare @retcode            int
    declare @subid              uniqueidentifier
    declare @REPOLEVersion_90   int
    declare @subscriber_db                              sysname

    select @publication = RTRIM(@publication)
    select @publisher_db = RTRIM(@publisher_db)
    set @REPOLEVersion_90= 90
    set @subscriber_db= db_name()

    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)

    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

   -- The database cannot subscribe to both Yukon and pre-Yukon publications.
   if @REPOLEVersion_90 = @backward_comp_level and
      exists (select * from dbo.sysmergepublications where 
                   backward_comp_level < @REPOLEVersion_90 and
                   (upper(publisher collate SQL_Latin1_General_CP1_CS_AS) <> upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) or 
                        publisher_db <> @publisher_db or 
                        name <> @publication))
    begin
       raiserror(21527, 16, -1, @publication, @subscriber_db)
       return (1)
    end
    else if @REPOLEVersion_90 > @backward_comp_level and
      exists (select * from dbo.sysmergepublications where 
                   backward_comp_level >= @REPOLEVersion_90 and
                   status is not null and       -- Pull subscribers have dummy backward_comp_level until they sync the first time. Skip those.
                   (upper(publisher collate SQL_Latin1_General_CP1_CS_AS) <> upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) or 
                        publisher_db <> @publisher_db or 
                        name <> @publication))
    begin
       raiserror(21528, 16, -1, @publication, @subscriber_db)
       return (1)
   end

    /*
    ** Populate the local copy of dbo.sysmergepublications
    */
    BEGIN TRAN
    save TRAN MSaddinitialpublication

    -- this proc gets called when we are adding the publication on the subscriber when a merge for
    -- this subscriber with the given publication happens for the first time. However, we could have
    -- a publication entry already if we know about this publication as a "global replica". To understand
    -- why a publication entry could already exists check sp_MScreateglobalreplica where we create a
    -- sysmergepublications entry for each publication replica (pubid = subid) we see
    -- however, this subscriber could be subscribing to this publication for the first time.
    if exists (select * from dbo.sysmergepublications 
            where name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db)
    begin 
        declare @pubid_local uniqueidentifier

        /* select the local pubid only if it has a valid parentid */
        select @pubid_local = pubid from dbo.sysmergepublications 
            where name = @publication and 
                UPPER(publisher)=UPPER(@publisher) and 
                publisher_db=@publisher_db
        if @pubid_local <> @pubid
        begin
            if exists (select * from dbo.sysmergesubscriptions 
                where pubid = @pubid and 
                UPPER(subscriber_server) collate database_default = UPPER(@publisher) and db_name = @publisher_db)
            begin
                select @subid = subid from dbo.sysmergesubscriptions 
                    where pubid = @pubid and UPPER(subscriber_server) collate database_default = UPPER(@publisher) and db_name = @publisher_db
                delete from dbo.MSmerge_replinfo where repid = @subid
                
				-- delete supportability settings for the subscriptions that we are about to delete.
			    delete from dbo.MSmerge_supportability_settings where subid = @subid       	
			    delete from dbo.MSmerge_log_files where subid = @subid
			        
                delete from dbo.sysmergesubscriptions where subid = @subid
                IF @@ERROR <> 0
                BEGIN
                    RAISERROR (14057, 16, -1)
                    goto FAILURE
                END
                
                                exec sys.sp_MScleanup_subscriber_history @subid=@subid
                                if @@ERROR<>0 
                                        goto FAILURE
            
                -- If the only remaining subscriptions are old entries (before restore),
                -- we remove them now.
                if not exists (select * from dbo.sysmergesubscriptions 
                                                        where status <> 7) -- REPLICA_STATUS_BeforeRestore
                begin
                        delete from dbo.sysmergesubscriptions
                        truncate table dbo.MSmerge_supportability_settings
                        truncate table dbo.MSmerge_log_files
                        truncate table dbo.MSrepl_errors
                                        truncate table dbo.MSmerge_history
                                        truncate table dbo.MSmerge_articlehistory
                                        truncate table dbo.MSmerge_sessions
                        delete from dbo.MSmerge_replinfo
                end
            end
        end
        update dbo.sysmergesubscriptions set pubid= @pubid, replicastate= newid() where pubid = @pubid_local
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14057, 16, -1)
                goto FAILURE
            END
        if @pubid <> @pubid_local
        begin
			-- delete supportability settings for the subscriptions that we are about to delete.
		    delete from dbo.MSmerge_supportability_settings where subid = @pubid       	
		    delete from dbo.MSmerge_log_files where subid = @pubid

            delete from dbo.sysmergesubscriptions where subid = @pubid
            exec sys.sp_MScleanup_subscriber_history @subid=@pubid
                        if @@ERROR<>0 
                                goto FAILURE
            delete from dbo.MSmerge_replinfo where repid = @pubid

            -- If the only remaining subscriptions are old entries (before restore),
            -- we remove them now.
            if not exists (select * from dbo.sysmergesubscriptions 
                                                where status <> 7) -- REPLICA_STATUS_BeforeRestore
            begin
                delete from dbo.sysmergesubscriptions
                truncate table dbo.MSmerge_supportability_settings
                truncate table dbo.MSmerge_log_files
                truncate table dbo.MSrepl_errors
                                truncate table dbo.MSmerge_history
                                truncate table dbo.MSmerge_articlehistory
                                truncate table dbo.MSmerge_sessions
                delete from dbo.MSmerge_replinfo
            end
        end
            
        update dbo.sysmergesubscriptions SET subid = @pubid, replnickname = isnull(@replnickname, replnickname) where subid = @pubid_local
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14057, 16, -1)
            goto FAILURE
        END
        delete from dbo.MSmerge_replinfo where repid = @pubid_local
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14057, 16, -1)
            goto FAILURE
        END
        update dbo.sysmergepublications 
            SET pubid = @pubid, 
                name = @publication, 
                description = @description, 
                designmasterid = @pubid, 
                retention = @retention, 
                retention_period_unit = @retention_period_unit,
                parentid = pubid, 
                sync_mode = sync_mode, 
                allow_push = @allow_push, 
                allow_pull = @allow_pull, 
                allow_anonymous = @allow_anonymous, 
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
                status = @status,
                snapshot_ready = @snapshot_ready,
                enabled_for_internet = @enabled_for_internet,
                publication_type = @publication_type,
                conflict_retention = @conflict_retention,
                allow_subscription_copy = @allow_subscription_copy, 
                allow_synctoalternate = @allow_synctoalternate ,
                backward_comp_level = @backward_comp_level,
                replicate_ddl=@replicate_ddl,
                generation_leveling_threshold = @generation_leveling_threshold,
                automatic_reinitialization_policy = @automatic_reinitialization_policy
            where name = @publication
                  and UPPER(publisher) = UPPER(@publisher)
                  and publisher_db = @publisher_db

        	-- Fix the replnick to 4 bytes + 0x0000 if the compatlevel is less than 80.
        	-- This prevents us from having real 6 byte replnicks when there are 80 subscribers
        	-- Having real 6 byte replnicks in mixed mode can cause non-convergence because the 
        	-- lineages can not be converted from 90 to 80 and back to 90 without losing last two bytes of replnick.
			if @REPOLEVersion_90 > @backward_comp_level
			begin
				update dbo.sysmergesubscriptions set replnickname = substring(replnickname,1,4) + 0x0000
					where pubid <> subid and pubid in (select pubid from sysmergepublications where name = @publication
    					              and UPPER(publisher) = UPPER(@publisher) and publisher_db = @publisher_db)
			end
                  
    end
    else
    begin
        insert dbo.sysmergepublications(publisher, publisher_db,pubid, name, description, designmasterid, 
            retention, parentid, sync_mode, allow_push, allow_pull, allow_anonymous, 
            centralized_conflicts, 
            decentralized_conflicts, 
            status, snapshot_ready, enabled_for_internet, publication_type, 
            conflict_retention, allow_subscription_copy, allow_synctoalternate, backward_comp_level, replicate_ddl, distributor,
            retention_period_unit, generation_leveling_threshold, automatic_reinitialization_policy)
        values(@publisher, @publisher_db, @pubid, @publication, @description, @pubid, 
            @retention, @pubid, @sync_mode, @allow_push, @allow_pull, @allow_anonymous, 
            case @conflict_logging -- centralized
               when 1 then 1
               when 2 then 1
               else 0
            end,
            case @conflict_logging -- decentralized
               when 1 then 0
               when 2 then 1
               else 1
            end,
            @status, @snapshot_ready, @enabled_for_internet, @publication_type, 
            @conflict_retention, @allow_subscription_copy, @allow_synctoalternate, @backward_comp_level, @replicate_ddl, @publisher,
            @retention_period_unit, @generation_leveling_threshold, @automatic_reinitialization_policy)
    end
    IF @@ERROR <> 0
        BEGIN
            RAISERROR (14057, 16, -1)
            goto FAILURE
        END
    COMMIT TRAN

    RETURN (0)

FAILURE:
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION MSaddinitialpublication
        COMMIT TRANSACTION
    end
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_MSaddinitialpublication] TO [public] AS [dbo]
GO
