SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreateglobalreplica]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreateglobalreplica] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreateglobalreplica]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@replicastate [uniqueidentifier],
	@replica_server [sysname],
	@replica_db [sysname],
	@replica_priority [real],
	@subscriber_type [tinyint],
	@subscription_type [int],
	@datasource_type [int],
	@datasource_path [nvarchar](255),
	@replnick [varbinary](6),
	@status [int],
	@sync_type [tinyint],
	@publication [sysname],
	@distributor [sysname],
	@replica_version [int],
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    DECLARE @pubnickname        int
    declare @retcode            int
    declare @backward_comp_level int

    -- Check to see if current publication has permission
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck  
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    
    -- NOTE
    select @replica_db = RTRIM(@replica_db)
    select @backward_comp_level= sys.fn_MSgetmaxbackcompatlevel ()

    /* Replnick in 80 was int and in 90 is binary(6). The proc
       does a implicit conversion from int to varbinary(6) but we still
       need to reverse the binary value to get a corresponding 90 replnick */
    if @compatlevel < 90
        set @replnick= cast(reverse(substring(@replnick,1,4)) as binary(4))+ 0x0000  

    exec sys.sp_MSget_server_portinfo 
        @name = @replica_server, 
        @srvname = @replica_server OUTPUT

    exec sys.sp_MSget_server_portinfo 
        @name = @distributor, 
        @srvname = @distributor OUTPUT

    BEGIN TRAN MScreateglobalreplica    
        /*
        ** Populate the local copy of dbo.sysmergesubscriptions
        */
        if exists (select * from dbo.sysmergesubscriptions where subid = @subid)
        begin
            update dbo.sysmergesubscriptions 
                SET datasource_type     = @datasource_type,
                    db_name             = @replica_db,
                    status              = @status,
                    subscriber_type     = @subscriber_type,
                    subscription_type   = @subscription_type,
                    priority            = @replica_priority,
                    sync_type           = @sync_type,
                    subscriber_server   = @replica_server,
                    replica_version = @replica_version
            where subid = @subid and pubid = @pubid                         
            IF @@ERROR <> 0
                goto FAILURE
                
            -- if the replica is a publications loop back global subscription
            -- add an entry to sysmergepublications
            if (@subid = @pubid)
            begin
                if exists (select * from dbo.sysmergepublications where pubid = @pubid)
                begin
                    update dbo.sysmergepublications
                    set distributor = @distributor
                    where pubid = @pubid
                    IF @@ERROR <> 0
                        goto FAILURE
                end
                else
                begin
                    -- added this to avoid problem of having too low a backward_comp_level
                    insert dbo.sysmergepublications(publisher, publisher_db, pubid, name, distributor, backward_comp_level)
                    values (@replica_server, @replica_db, @pubid, @publication, @distributor, @backward_comp_level)
                    IF @@ERROR <> 0
                        goto FAILURE
              end
            end
        end
        else
        begin
            /* 
            ** If attempting to tell the current replica about another replica whose pubid IS NULL
            ** ignore the insert because current replica has more current info.
            */
            if exists (select * from dbo.sysmergesubscriptions where subid = @subid and @pubid IS NULL)
                goto SUCCESS
                
            IF EXISTS (SELECT * FROM dbo.sysmergesubscriptions 
                       WHERE UPPER(subscriber_server) collate database_default = UPPER(@replica_server) collate database_default AND 
                             db_name = @replica_db and pubid = @pubid)
                goto SUCCESS

            -- if this is an attempt to tell this replica about itself ignore it since this replica will always have the most
            -- recent information about itself.
            if (@subid=@pubid) and 
                    exists (select 1 from dbo.sysmergepublications 
                            where UPPER(publisher) = UPPER(@replica_server) and publisher_db = @replica_db and pubid <> @pubid)
                    and UPPER(@replica_server) = UPPER(publishingservername())
                    and @replica_db = db_name()
                goto SUCCESS
            
            -- now check if this is a publication's loopback global replica entry. If so we need to do something different.
            if (@subid = @pubid)
            begin
                -- There is a possibility that the subscriber has a subscription to this publication and that subscription
                -- has not gone through a first sync yet and was added using addmergepullsubscription. In that case even though
                -- the replica entry is there it would have the wrong pubid. By creating a global replica here we would be duplicating
                -- the sysmergepublications and sysmergesubscriptions entries for the publications loop back replica. Hence just
                -- do an update here instead of an insert.
                declare @pubid_local uniqueidentifier

                -- now check if there is a replica entry to this publication with a different pubid
                select @pubid_local = pubid from dbo.sysmergepublications 
                    where name = @publication and UPPER(publisher)=UPPER(@replica_server) and publisher_db=@replica_db
                if @pubid_local is not NULL
                begin
                    if exists (select * from dbo.sysmergesubscriptions where pubid = @pubid_local and subid = pubid)
                    begin
                        update dbo.sysmergesubscriptions 
                            SET pubid = @pubid,
                                subid = @subid,
                                datasource_type     = @datasource_type,
                                db_name             = @replica_db,
                                status              = @status,
                                subscriber_type     = @subscriber_type,
                                subscription_type   = @subscription_type,
                                priority            = @replica_priority,
                                sync_type           = @sync_type,
                                subscriber_server   = @replica_server,
                                replica_version = @replica_version
                            where subid = pubid and pubid = @pubid_local
                        IF @@ERROR <> 0
                            goto FAILURE
                    end
                    else
                    begin
                        -- this case happens when create global replica is called after addinitial subscription
                        insert dbo.sysmergesubscriptions(subid, replicastate, datasource_type,  
                            db_name, pubid, status, subscriber_type, subscription_type, priority, 
                            sync_type, subscriber_server, replnickname, replica_version)
                        values (@subid, @replicastate, @datasource_type, 
                            @replica_db, @pubid, @status, @subscriber_type, @subscription_type, @replica_priority, 
                            @sync_type, @replica_server, @replnick, @replica_version)
                        IF @@ERROR <> 0
                            goto FAILURE
                    end
                        
                    update dbo.sysmergepublications
                        set pubid = @pubid,
                            distributor = @distributor
                        where pubid = @pubid_local
                    IF @@ERROR <> 0
                        goto FAILURE

                    -- In some instances, there can be entries from deleted publications in
                    -- sysmergesubscriptions that have the same db_name and subscriber_server
                    -- as a current publication.
                    -- The below update needs to be restricted to not reassign the pubid on
                    -- old entries where a new entry already exists as this will violate the unique
                    -- constraint across pubid, subscriber_server, and db_name.
                    -- See VSTS 82551 and 161794.
                    update dbo.sysmergesubscriptions
                        set pubid = @pubid 
                        where pubid = @pubid_local 
                        and subid not in (select sms1.subid from dbo.sysmergesubscriptions sms1 join
                                                                 dbo.sysmergesubscriptions sms2 on
                                                                 sms1.subscriber_server = sms2.subscriber_server and
                                                                 sms1.db_name = sms2.db_name
                                                                 where sms1.pubid = @pubid_local and
                                                                 sms2.pubid = @pubid)                   
                    IF @@ERROR <> 0
                        goto FAILURE
                        
                    update dbo.sysmergearticles
                        set pubid = @pubid 
                        where pubid = @pubid_local
                    IF @@ERROR <> 0
                        goto FAILURE
                end
                else
                begin
                    -- if we get here it means that we do not already know about this replica and so do the inserts
                    insert dbo.sysmergesubscriptions(subid, replicastate, datasource_type,  
                        db_name, pubid, status, subscriber_type, subscription_type, priority, 
                        sync_type, subscriber_server, replnickname, replica_version)
                    values (@subid, @replicastate, @datasource_type, 
                        @replica_db, @pubid, @status, @subscriber_type, @subscription_type, @replica_priority, 
                        @sync_type, @replica_server, @replnick, @replica_version)
                    IF @@ERROR <> 0
                        goto FAILURE

                    -- Null values in field [retention] in sysmergepublications table is impacting clean up procedure sp_mergemetadataretentioncleanup
                    -- For CE subscribers. Fix is to use a small (1) Retention value, this should effectively remove these rows from the cleanup date
                    -- calculation but still allow cleanup.
                    insert dbo.sysmergepublications(publisher, publisher_db, pubid, name, distributor, backward_comp_level, retention, retention_period_unit)
                    values (@replica_server, @replica_db, @pubid, @publication, @distributor, @backward_comp_level, 1, 0)
                    IF @@ERROR <> 0
                        goto FAILURE
                end
            end
            else
            begin
                insert dbo.sysmergesubscriptions(subid, replicastate, datasource_type,  
                    db_name, pubid, status, subscriber_type, subscription_type, priority, 
                    sync_type, subscriber_server, replnickname, replica_version)
                values (@subid, @replicastate, @datasource_type, 
                    @replica_db, @pubid, @status, @subscriber_type, @subscription_type, @replica_priority, 
                    @sync_type, @replica_server, @replnick, @replica_version)
                IF @@ERROR <> 0
                    goto FAILURE
            end
        end
            
        -- 9.0 publications use 6 byte replnicks. If we did sp_addmergepullsubscription for such
        -- a publication, we currently have a 4 byte nickname only for our own replica. 
        -- If we do not already have a used nickname for the replica, we now change
        -- that nickname to 6 bytes.
        select @backward_comp_level= backward_comp_level from dbo.sysmergepublications where pubid = @pubid
        if @backward_comp_level >= 90
        begin
            declare @newsubnick binary(6)
            declare @srcguid uniqueidentifier

            set @srcguid= newid()
            
            exec sys.sp_MSgenreplnickname 
                @srcguid=         @srcguid, 
                @replnick=         @newsubnick output,
                @compatlevel=     @backward_comp_level

            update sub
                set sub.replnickname= @newsubnick
                from dbo.sysmergesubscriptions as sub
                where
                    -- only update if not already a real 6 byte nickname
                    substring(sub.replnickname, 5, 2) = 0x0000
                    and
                    -- only update that specific nickname
                    sub.pubid = @pubid and sub.subid <> @pubid and sub.db_name = db_name()
                    and
                    -- only update if the nickname not already exists for another subscription
                    2 > (select count(*) from dbo.sysmergesubscriptions 
                            where replnickname = sub.replnickname)
        end

SUCCESS:            
    COMMIT TRAN         
    RETURN 0

FAILURE:
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT = 1 
        ROLLBACK TRANSACTION MScreateglobalreplica
    else
        COMMIT TRANSACTION
    
    RAISERROR (14057, 16, -1)
    RETURN 1
GO
GRANT EXECUTE ON [sys].[sp_MScreateglobalreplica] TO [public] AS [dbo]
GO
