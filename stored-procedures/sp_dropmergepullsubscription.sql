SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergepullsubscription]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */

    declare @retcode                int
    declare @pubid                  uniqueidentifier
    declare @subid                  uniqueidentifier
    declare @local_db               sysname
    declare @merge_jobid            binary(16)
    declare @job_step_uid 			uniqueidentifier
    declare @cmd                    nvarchar(255)
    declare @pubidstr               nvarchar(38)
    declare @subscriber             sysname
    declare @subscriber_db          sysname
    declare @subscriber_type        int
    declare @local_job              bit
    declare @implicit_transaction   int
    declare @close_cursor_at_commit int
    declare @owner_sid              varbinary(85)
    declare @owner_name             sysname
    declare @qualified_publication_name nvarchar(512)
    declare @subscriber_type_anon   tinyint
    declare @REPLICA_STATUS_BeforeRestore tinyint

    set @subscriber_type_anon= 3
    set @REPLICA_STATUS_BeforeRestore= 7

    select @close_cursor_at_commit = 0
    select @implicit_transaction = 0

    /*
    ** Get original setting values before setting them to false for recursive calling
    */
    IF (@reserved = 0)
    BEGIN
        SELECT @implicit_transaction = @@options & 2
        SELECT @close_cursor_at_commit = @@options & 4
        SET IMPLICIT_TRANSACTIONS OFF
        SET CURSOR_CLOSE_ON_COMMIT OFF
    END

    /* 
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

     /*
    ** Initializations.
    */              
    set @local_db = DB_NAME()
    set @subscriber = @@SERVERNAME   
    set @subscriber_db = DB_NAME()

   /*
    ** Assign parameter values appropriately
    */    
    IF object_id('dbo.sysmergesubscriptions', 'U') is null
    BEGIN
        RAISERROR (14055, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is defined
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_dropmergepullsubscription')
        RETURN (1)
    END

    EXECUTE @retcode = sys.sp_validname @publisher
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)

    /*
    ** Parameter Check: @publisher_db
    */
    IF @publisher_db IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher_db', 'sp_dropmergepullsubscription')
        RETURN (1)
    END    

    -- Get publisher port number
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    /*
    ** Parameter Check:  @publication.
    ** If the publication name is specified, check to make sure that it
    ** conforms to the rules for identifiers and that the publication
    ** actually exists.  Disallow NULL.
    */
    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_dropmergepullsubscription')
        RETURN (1)
    END

    IF LOWER(@publication) = 'all'
    BEGIN
            declare hC1 CURSOR LOCAL FAST_FORWARD FOR 
                select DISTINCT name FROM dbo.sysmergepublications 
                FOR READ ONLY        
        OPEN hC1
        FETCH hC1 INTO @publication
        if @@fetch_status = -1 
        begin
            CLOSE hC1
            DEALLOCATE hC1
            RETURN (0) --- It's OK to have no publication when 'ALL'
        end
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergepullsubscription @publication = @publication,
                              @publisher = @publisher,
                              @publisher_db = @publisher_db,
                              @reserved = 1
            FETCH hC1 INTO @publication
        END
        CLOSE hC1
        DEALLOCATE hC1
        RETURN (0)
    END
        
    IF LOWER(@publisher) = 'all'
    BEGIN
        declare hC4 CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT publisher FROM dbo.sysmergepublications 
            FOR READ ONLY
        OPEN hC4
        FETCH hC4 INTO @publisher
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergepullsubscription @publication = @publication,
                                        @publisher = @publisher,
                                        @publisher_db = @publisher_db,
                                        @reserved = 1
            FETCH hC4 INTO @publisher
        END
        CLOSE hC4
        DEALLOCATE hC4
        RETURN (0)
    END

    /*
    ** Validate that the publisher is a valid server
    */
    /*
    select @publisher_srvid = srvid from master.dbo.sysservers where UPPER(srvname) = UPPER(@publisher) collate database_default
    IF @publisher_srvid IS NULL
    BEGIN
        RAISERROR (14080, 16, -1, @publisher)
        RETURN (1)
    END
    */

    /* Previously the condition is set as 'AND subid<>pubid' which is fatally errorous */
    IF LOWER(@publisher_db) = 'all'
    BEGIN
        declare hC5 CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT publisher_db 
            FROM dbo.sysmergepublications 
            WHERE upper(publisher collate SQL_Latin1_General_CP1_CS_AS)=upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) and 
                  name=@publication
            FOR READ ONLY

        OPEN hC5
        FETCH hC5 INTO @publisher_db
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergepullsubscription @publication = @publication,
                              @publisher = @publisher,
                              @publisher_db = @publisher_db,
                              @reserved = 1
            FETCH hC5 INTO @publisher_db
        END
        CLOSE hC5
        DEALLOCATE hC5
        RETURN (0)
    END

    /*
    ** return error if only there is no 'ALL'. Same is true for the rest of error handling.
    */

    select @pubid= pubid from dbo.sysmergepublications 
        where name = @publication and 
              upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) and 
              publisher_db = @publisher_db
    if @pubid is null  
    BEGIN
        if @reserved = 0
            RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END

    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''
    /*
    ** Only members of the sysadmin group and the creator of the distribution
    ** agent can drop a pull subscription successfully. This behavior matches 
    ** the behavior of the sysjobs_view. DBO of the subscriber database, 
    ** sysadmins (owner is undefined) can drop a subscription if the owner_sid 
    ** is null.
    */
    
    EXEC sys.sp_MSget_mergepullsubsagent_owner @publisher = @publisher,
                                               @publisher_db = @publisher_db,
                                               @publication = @publication,
                                               @owner_sid = @owner_sid OUTPUT 
    
    IF (@owner_sid is not null AND
        (SUSER_SID() <> @owner_sid) AND
        (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0))
    BEGIN
        SELECT @owner_name = SUSER_SNAME(@owner_sid)
        SELECT @qualified_publication_name = @publisher + N':' + 
                                             @publisher_db + N':' +
                                             @publication
        RAISERROR(21121,16,-1,@owner_name, @qualified_publication_name) 
        RETURN (1)
    END

    /*
    ** Get subscriptions from either local replicas or global replicas
    */
    /*
    select @subid = subs1.subid, @subscriber_type = subs1.subscriber_type from
        dbo.sysmergesubscriptions   subs1,
        dbo.sysmergesubscriptions   subs2,
        dbo.sysmergepublications    pubs
        where subs1.srvid = @subscriber_srvid
            and subs1.db_name = @subscriber_db
            and subs2.srvid = @publisher_srvid
            and subs2.db_name = @publisher_db
            and subs1.pubid = subs2.subid
            and subs2.pubid = pubs.pubid
            and pubs.name = @publication
            and upper(pubs.publisher collate SQL_Latin1_General_CP1_CS_AS)=upper(@publisher collate SQL_Latin1_General_CP1_CS_AS)
            and pubs.publisher_db=@publisher_db
   */
    select @subid = subid from dbo.sysmergesubscriptions 
        where pubid = @pubid and pubid <> subid and db_name = @subscriber_db and UPPER(subscriber_server) = UPPER(@subscriber)
    if @subid IS NULL 
    begin
        if @reserved = 0 
            raiserror (14050, 16, -1)
        RETURN (0)
    end                 

    exec @retcode = sys.sp_resetsnapshotdeliveryprogress @drop_table = N'true'
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end

    begin tran
    save TRAN dropmergepullsubscription
    
    /*  
    ** Drop the local merge task
    */
    select @merge_jobid = merge_jobid from dbo.MSmerge_replinfo WHERE repid = @subid

    if (@merge_jobid IS NOT NULL)
    BEGIN
        IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @merge_jobid)
        BEGIN
        	SELECT @job_step_uid = job_step_uid
		    FROM MSsubscription_properties
		    WHERE UPPER(publisher) = UPPER(@publisher)
		       AND publisher_db = @publisher_db
		       AND publication = @publication
		       AND publication_type = 2
		       
            -- Checks if the job name matches one that is generated
            -- by replication
            EXEC @retcode = sys.sp_MSispullmergejobnamegenerated
                                @publisher = @publisher,
                                @publisher_db = @publisher_db,
                                @publication = @publication,
                                @job_id = @merge_jobid
            IF @@ERROR <> 0
                GOTO FAILURE

            -- Only drop the job if the name was generated
            IF @retcode = 0
            BEGIN
                EXEC @retcode = sys.sp_MSdrop_repl_job @job_id = @merge_jobid,
                										@job_step_uid = @job_step_uid 
                IF @@ERROR <> 0 or @retcode <> 0
                    GOTO FAILURE
            END
        END
    END                                 

    if @subid <> @pubid
    BEGIN
        DELETE dbo.MSmerge_replinfo WHERE repid = @subid 
        IF @@ERROR <> 0
            GOTO FAILURE

		-- delete supportability settings for the subscriptions that we are about to delete.
        delete from dbo.MSmerge_supportability_settings where subid = @subid        	
        delete from dbo.MSmerge_log_files where subid = @subid

        delete from dbo.sysmergesubscriptions where subid = @subid
        if @@ERROR <> 0
            GOTO FAILURE
            
        exec sys.sp_MScleanup_subscriber_history @subid=@subid
		if @@ERROR <> 0
            GOTO FAILURE
            
        /* Call sp_MSunregistersubscription so that the reg entries get deleted */
        exec @retcode = sys.sp_MSunregistersubscription @publisher = @publisher,
                                    @publisher_db = @publisher_db,
                                    @publication = @publication,
                                    @subscriber = @@SERVERNAME,
                                    @subscriber_db = @subscriber_db
        IF @retcode<>0 or @@ERROR<>0
            GOTO FAILURE

        exec @retcode= sys.sp_MSpublicationcleanup @publisher=@publisher, 
                                        @publisher_db = @publisher_db,
                                        @publication = @publication,
                                        @force_preserve_rowguidcol = 0
        IF @retcode<>0 or @@ERROR <> 0 
        BEGIN
            RAISERROR (20025, 16, -1, @publication)
            GOTO FAILURE
        END

        -- If the only remaining subscriptions are old entries (before restore),
        -- we remove them now.
        if not exists (select * from dbo.sysmergesubscriptions 
                            where status <> @REPLICA_STATUS_BeforeRestore)
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
    END

    IF object_id('MSsubscription_properties', 'U') is not NULL
    BEGIN
        DELETE FROM MSsubscription_properties 
        WHERE upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(@publisher collate SQL_Latin1_General_CP1_CS_AS)    AND
        publisher_db  = @publisher_db AND
        publication = @publication 

        IF @@ERROR <> 0 
            GOTO FAILURE

        IF NOT EXISTS (SELECT * FROM MSsubscription_properties)
        BEGIN
            exec @retcode = sys.sp_MSsub_cleanup_prop_table
            IF @@ERROR <> 0 or @retcode <> 0
                GOTO FAILURE
        END
    END

    COMMIT TRAN
    /*
    ** Set back original settings
    */
    IF @reserved = 0
    BEGIN
        declare @whattodrop int    -- 1=hws, 2=lws, 3=both
        set @whattodrop= 0

        if not exists (select * from dbo.sysmergesubscriptions
                            where subscription_type <> 3 and
                                  status <> @REPLICA_STATUS_BeforeRestore)
        begin
            set @whattodrop= 1
        end
                
        if not exists (select * from dbo.sysmergesubscriptions
                            where subscription_type = 3 and
                                  status <> @REPLICA_STATUS_BeforeRestore)
        begin
            set @whattodrop= @whattodrop + 2
        end

        /* 
        ** If last subscription is dropped and the DB is not enabled for publishing,
        ** then remove the merge system tables
        */
        if 0 <> @whattodrop and
           0 = (select category & 4 FROM master.dbo.sysdatabases WHERE name = DB_NAME())
        begin
            execute @retcode= sys.sp_MSdrop_mergesystables @whattodrop=@whattodrop
            if @@ERROR <> 0 or @retcode <> 0 return (1)

            execute @retcode=sys.sp_MSrepl_ddl_triggers @type='merge', @mode='drop'
            if @@ERROR <> 0 or @retcode <> 0 goto FAILURE            
        end

        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END

    -- note that here we will ignore any errors.
    EXEC sys.sp_dropreplsymmetrickey @check_replication = 1, @throw_error = 0

    RETURN(0)       

FAILURE:
    RAISERROR (14056, 16, -1)
    if @@trancount > 0
    begin
        ROLLBACK TRANSACTION dropmergepullsubscription
        COMMIT TRANSACTION
    end
    /*
    ** Set back original settings
    */  
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    return 1
GO
GRANT EXECUTE ON [sys].[sp_dropmergepullsubscription] TO [public] AS [dbo]
GO
