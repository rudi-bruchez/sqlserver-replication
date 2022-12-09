SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddinitialsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddinitialsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddinitialsubscription]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@replicastate [uniqueidentifier],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscriber_priority [real],
	@subscriber_type [tinyint],
	@subscription_type [int],
	@sync_type [tinyint],
	@publication [sysname],
	@distributor [sysname],
	@replica_version [int]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    DECLARE @local              tinyint
    DECLARE @anonymous          tinyint
    DECLARE @subnickname        varbinary(6)
    DECLARE @inactive             tinyint
    DECLARE @retcode            int
    DECLARE @subid_old          uniqueidentifier

    
    SET @local              = 2
    SET @anonymous          = 3

    exec sys.sp_MSget_server_portinfo 
        @name = @subscriber, 
        @srvname = @subscriber OUTPUT

    -- This adds an inactive initial subscription. The subscription is activated
    -- only after the first successful merge.
    set @inactive             = 0
    

    select @subscriber_db = RTRIM(@subscriber_db)
    /*
    ** Check for subscribing permission
    ** It is called by merge agent at the publisher side
    ** subscriber side?
    */
    -- @pubid is not local
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
                RAISERROR (21723, 16, -1, 'sp_MSaddinitialsubscription')
                return 1
        end
        else
        begin
                RAISERROR (14126, 11, -1)
                return 1
        end
    end

    -- this gets executed at both publisher (for pull subscriptions) and at subscriber

    begin tran
    save TRAN MSaddinitialsubscription  
    /*
    ** Populate the local copy of dbo.sysmergesubscriptions
    */
    if exists (select * from dbo.sysmergesubscriptions where subid = @subid)
    begin
        update dbo.sysmergesubscriptions 
            SET datasource_type = 0,
                db_name = @subscriber_db,
                pubid = @pubid,
                status = @inactive,
                subscriber_type = @subscriber_type,
                subscription_type = @subscription_type,
                priority = @subscriber_priority,
                sync_type = @sync_type,
                subscriber_server = @subscriber,
                replica_version = @replica_version
            where subid = @subid 
                    
        IF @@ERROR <> 0
        BEGIN
            goto FAILURE
        END
    end                 
                    
    if exists (select * from dbo.sysmergesubscriptions 
               where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default AND 
                     db_name = @subscriber_db AND pubid = @pubid)
    begin
        select @subid_old = subid from dbo.sysmergesubscriptions 
            where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default AND 
                  db_name = @subscriber_db AND pubid = @pubid
        update dbo.sysmergesubscriptions 
            SET subid = @subid,
                datasource_type = 0,
                db_name = @subscriber_db,
                pubid = @pubid,
                status = @inactive,
                subscriber_type = @subscriber_type,
                subscription_type = @subscription_type,
                priority = @subscriber_priority,
                sync_type = @sync_type,
                subscriber_server = @subscriber,
                replica_version = @replica_version
            where subid = @subid_old
                    
        IF @@ERROR <> 0
        BEGIN
            goto FAILURE
        END

		-- Update the subid in supportability tables aswell if it exists.
        update dbo.MSmerge_supportability_settings set subid = @subid where subid = @subid_old
        update dbo.MSmerge_log_files set subid = @subid where subid = @subid_old
		        
        if (@subid_old IS NOT NULL)
        begin
            /*
            **  update old row for subscriber from dbo.MSmerge_replinfo.
            */
            update dbo.MSmerge_replinfo set repid = @subid where repid = @subid_old
            IF @@ERROR <> 0
            BEGIN
                goto FAILURE
            END

            EXECUTE @retcode = sys.sp_MSgenreplnickname 
                                    @srcguid= @subid, 
                                    @replnick= @subnickname output
            if @@ERROR<>0 or @retcode<>0 goto FAILURE
            
            /*
            **  Update replnickname is sysmergesubscriptions
            */
            update dbo.sysmergesubscriptions set replnickname = @subnickname where subid = @subid 
            IF @@ERROR <> 0
            BEGIN
                goto FAILURE
            END
        end                 
    end
    else
    begin
        /* Look for existing nickname from any other subscription */
        select @subnickname = max(replnickname) from dbo.sysmergesubscriptions 
           where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default 
                and db_name = @subscriber_db
                and status <> 7 -- REPLICA_STATUS_BeforeRestore
                
        /* Generate a new replica nickname from the @subid */
        if (@subnickname is null)
        begin
            EXECUTE @retcode = sys.sp_MSgenreplnickname 
                                        @srcguid= @subid, 
                                        @replnick= @subnickname output
            if @@ERROR<>0 or @retcode<>0 goto FAILURE
        end
        
        INSERT dbo.sysmergesubscriptions(subid,
                                  replicastate,
                                  db_name, 
                                  pubid,
                                  status, 
                                  subscriber_type,
                                  subscription_type,
                                  priority, 
                                  sync_type, 
                                  description,
                                  replnickname,
                                  subscriber_server,
                                  replica_version)
            VALUES (@subid,
                    newid(),
                    @subscriber_db,
                    @pubid,
                    @inactive,
                    @subscriber_type,
                    @subscription_type,
                    @subscriber_priority,
                    @sync_type, 
                    NULL, 
                    @subnickname,
                    @subscriber,
                    @replica_version)

        IF @@ERROR <> 0
        BEGIN
            goto FAILURE
        END

        /*
        **  Add row for subscriber to dbo.MSmerge_replinfo.
        */
        INSERT INTO  dbo.MSmerge_replinfo(repid, login_name )  
            values (@subid, suser_sname(suser_sid())) 
        IF @@ERROR <> 0
        BEGIN
            goto FAILURE
        END
    end                                     

    COMMIT TRAN         
    RETURN 0

FAILURE:
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION MSaddinitialsubscription
        COMMIT TRANSACTION
    end
    
    RAISERROR (14057, 16, -1)
    RETURN 1
GO
GRANT EXECUTE ON [sys].[sp_MSaddinitialsubscription] TO [public] AS [dbo]
GO
