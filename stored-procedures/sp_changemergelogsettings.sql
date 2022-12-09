SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergelogsettings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergelogsettings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergelogsettings]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@support_options [int],
	@web_server [sysname],
	@log_severity [int],
	@log_modules [int],
	@log_file_path [nvarchar](255),
	@log_file_name [sysname],
	@log_file_size [int],
	@no_of_log_files [int],
	@upload_interval [int],
	@delete_after_upload [int],
	@custom_script [nvarchar](2000),
	@message_pattern [nvarchar](2000),
	@agent_xe [varbinary](max),
	@agent_xe_ring_buffer [varbinary](max),
	@sql_xe [varbinary](max)
WITH EXECUTE AS CALLER
AS
declare @retcode                int
    declare @pubid                    uniqueidentifier
    declare @subid                    uniqueidentifier

    declare @log_sev_lobyte       int
    declare @log_sev_hibyte       int

    /*
    ** Security Check.
    */
    exec @retcode= sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(15247,-1,-1)
        return (1)
    end


    /*
    **    Check to see if current database is doing publishing/subscribing
    */
    IF object_id('sysmergesubscriptions') is NULL
    BEGIN
        RAISERROR (14055, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @publication.
    ** Make sure that the publication exists.
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_changemergelogsettings')
            RETURN (1)
        END

    select @pubid = pubid
       FROM dbo.sysmergepublications 
       WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    IF @pubid IS NULL
    BEGIN
        RAISERROR (20026, 11, -1, @publication)
        RETURN (1)
    END

    
    /*
    ** Parameter Check:     @subscriber.
    ** Check to make sure we have a valid subscriber.
    */
    IF @subscriber IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@subscriber', 'sp_changemergelogsettings')
        RETURN (1)
    END
    
    /*
    ** Parameter Check:     @subscriber_db.
    ** Check to make sure we have a valid subscriber.
    */
    IF @subscriber_db IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@subscriber_db', 'sp_changemergelogsettings')
        RETURN (1)
    END
        
    /*
    ** Check to see if you have a subscription on this publication
    */
    set @subid = NULL
    select @subid = subid, @pubid = pubid /* identified from publication name */
          from dbo.sysmergesubscriptions
        where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
            and db_name = @subscriber_db
            
    if @subid IS NULL 
        begin
            RAISERROR (14050, 11, -1)
            RETURN(1)
        end                    

	if not exists (select * from dbo.MSmerge_supportability_settings
			    WHERE pubid = @pubid and subid = @subid and
			        ((@web_server IS NULL and web_server IS NULL) or (@web_server IS NOT NULL and
			        UPPER(web_server) collate database_default = UPPER(@web_server) collate database_default )))
    begin
	    RAISERROR (20718, 16, -1, @subscriber, @subscriber_db,@web_server)
        RETURN(1)
    end

    /*
    ** Parameter Check: all other parameters
    ** 
    */

    if (@support_options IS NOT NULL) and (@support_options < 0 or @support_options > 5)
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@support_options')
        RETURN(1)
    end                    

    set @log_sev_lobyte = @log_severity & 0xF
    set @log_sev_hibyte = @log_severity & 0xF0
    
    if (@log_severity IS NOT NULL) and ((@log_sev_lobyte < 0 or @log_sev_lobyte > 5) or (@log_sev_hibyte < 0 or @log_sev_hibyte > 1))
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@log_severity')
        RETURN(1)
    end                    

    if (@log_file_size IS NOT NULL) and (@log_file_size < 2000000 or @log_file_size > 999000000)
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@log_file_size')
        RETURN(1)
    end                    

    if (@no_of_log_files IS NOT NULL) and (@no_of_log_files < 2 or @no_of_log_files > 500)
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@no_of_log_files')
        RETURN(1)
    end                    

    if (@upload_interval IS NOT NULL) and (@upload_interval < 0 or @upload_interval > 40320)	-- 60 * 24 * 7 *4 (4 weeks)
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@upload_interval')
        RETURN(1)
    end                    

    if (@delete_after_upload IS NOT NULL) and (@delete_after_upload not in (0,1))
    begin
        RAISERROR (20722, 16, -1, 'sp_changemergelogsettings', '@delete_after_upload')
        RETURN(1)
    end                    

    begin tran
    save TRAN changemergelogsettings

	update dbo.MSmerge_supportability_settings
		set support_options = case when (@support_options IS NULL) 		then support_options else @support_options end
		,log_severity 	    = case when (@log_severity IS NULL) 		then log_severity 	 else @log_severity end
		,log_modules 		= case when (@log_modules IS NULL) 		    then log_modules 	 else @log_modules end
		,log_file_path 		= case when (@log_file_path IS NULL) 		then log_file_path 	 else @log_file_path end
		,log_file_name 		= case when (@log_file_name IS NULL) 		then log_file_name 	 else @log_file_name end
		,log_file_size 		= case when (@log_file_size IS NULL) 		then log_file_size   else @log_file_size end
		,no_of_log_files 	= case when (@no_of_log_files IS NULL) 		then no_of_log_files else @no_of_log_files end
		,upload_interval 	= case when (@upload_interval IS NULL) 		then upload_interval else @upload_interval end
		,delete_after_upload    = case when (@delete_after_upload IS NULL) 	then delete_after_upload else @delete_after_upload end
		,custom_script          = case when (@custom_script IS NULL or @web_server IS NOT NULL) 	then custom_script else @custom_script end
		,message_pattern        = case when (@message_pattern IS NULL) 	        then message_pattern     else @message_pattern end
		,agent_xe              = case when (@agent_xe IS NULL) 	        then agent_xe else @agent_xe end
		,agent_xe_ring_buffer       = case when (@agent_xe_ring_buffer IS NULL) 	        then agent_xe_ring_buffer else @agent_xe_ring_buffer end
		,sql_xe                  = case when (@sql_xe IS NULL) 	            then sql_xe else @sql_xe end
	
    WHERE pubid = @pubid and subid = @subid and
        ((@web_server IS NULL and web_server IS NULL) or (@web_server IS NOT NULL and
        UPPER(web_server) collate database_default = UPPER(@web_server) collate database_default ))
	

    if @@ERROR <> 0
    BEGIN
        GOTO FAILURE
    END

	-- Get the subscriber out of supportability mode if there are no
	-- entries for the subscriber with support_options turned on.
	if not exists ( select * from dbo.MSmerge_supportability_settings
		WHERE pubid = @pubid and subid = @subid and
        support_options <> 0
		)
	begin
		update dbo.sysmergesubscriptions
			set supportability_mode = 0
		where subid = @subid and pubid = @pubid

	    if @@ERROR <> 0
	    BEGIN
	        GOTO FAILURE
	    END
	
	end
	else
	begin
		update dbo.sysmergesubscriptions
			set supportability_mode = 1
		where subid = @subid and pubid = @pubid

	    if @@ERROR <> 0
	    BEGIN
	        GOTO FAILURE
	    END
	end

    COMMIT TRAN
    return (0)

FAILURE:
    RAISERROR (20719, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION changemergelogsettings
        COMMIT TRANSACTION
    end
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_changemergelogsettings] TO [public] AS [dbo]
GO
