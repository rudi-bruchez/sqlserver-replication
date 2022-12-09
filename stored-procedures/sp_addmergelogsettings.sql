SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergelogsettings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergelogsettings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergelogsettings]
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
            RAISERROR (14043, 16, -1, '@publication', 'sp_addmergelogsettings')
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
        RAISERROR (14043, 16, -1, '@subscriber', 'sp_addmergelogsettings')
        RETURN (1)
    END
    
    /*
    ** Parameter Check:     @subscriber_db.
    ** Check to make sure we have a valid subscriber.
    */
    IF @subscriber_db IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@subscriber_db', 'sp_addmergelogsettings')
        RETURN (1)
    END

    /*
    ** Check to see if you have a subscription on this publication
    */
    set @subid = NULL
    select @subid = subid
          from dbo.sysmergesubscriptions
        where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
            and db_name = @subscriber_db
            and pubid = @pubid  /* identified from publication name */
            
    if @subid IS NULL 
        begin
            RAISERROR (14050, 11, -1)
            RETURN(1)
        end                    

    /*
    ** Parameter Check: all other parameters
    ** 
    */
    if @support_options < 0 or @support_options > 5
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@support_options')
        RETURN(1)
    end                    

    set @log_sev_lobyte = @log_severity & 0xF
    set @log_sev_hibyte = @log_severity & 0xF0
    
    if (@log_severity IS NOT NULL) and ((@log_sev_lobyte < 0 or @log_sev_lobyte > 5) or (@log_sev_hibyte < 0 or @log_sev_hibyte > 1))
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@log_severity')
        RETURN(1)
    end                    

    if @log_file_size < 2000000 or @log_file_size > 999000000
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@log_file_size')
        RETURN(1)
    end                    

    if @no_of_log_files < 2 or @no_of_log_files > 500
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@no_of_log_files')
        RETURN(1)
    end                    

    if @upload_interval < 0 or @upload_interval > 40320	-- 60 * 24 * 7 *4 (4 weeks)
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@upload_interval')
        RETURN(1)
    end                    

    if @delete_after_upload not in (0,1)
    begin
        RAISERROR (20722, 16, -1, 'sp_addmergelogsettings', '@delete_after_upload')
        RETURN(1)
    end                    

    begin tran
    save TRAN addmergelogsettings

    -- custom script is ignored when setting web_server log settings
    if @web_server IS NOT NULL
    begin
        select @custom_script = NULL
    end

	if not exists (select * from dbo.MSmerge_supportability_settings
			    WHERE pubid = @pubid and subid = @subid and
			        ((@web_server IS NULL and web_server IS NULL) or (@web_server IS NOT NULL and
			        UPPER(web_server) collate database_default = UPPER(@web_server) collate database_default )))
	begin
	
        	insert into dbo.MSmerge_supportability_settings 
        	    (pubid, subid, web_server, support_options, log_severity, log_modules, log_file_path, log_file_name, log_file_size, 
        	    no_of_log_files, upload_interval, delete_after_upload,custom_script,message_pattern, agent_xe, agent_xe_ring_buffer, sql_xe)
        	    
        	values(@pubid, @subid, @web_server, @support_options, @log_severity, @log_modules, @log_file_path, @log_file_name, @log_file_size, 
        	    @no_of_log_files, @upload_interval, @delete_after_upload,@custom_script,@message_pattern, @agent_xe, @agent_xe_ring_buffer, @sql_xe)
        end
    else
        begin
            -- call update proc
            exec sp_changemergelogsettings @publication, @subscriber, @subscriber_db, @support_options, @web_server, @log_severity, @log_modules, @log_file_path, @log_file_name, @log_file_size, @no_of_log_files, @upload_interval, @delete_after_upload, @custom_script, @message_pattern, @agent_xe, @agent_xe_ring_buffer, @sql_xe
        end
	    
    if @@ERROR <> 0
    BEGIN
        GOTO FAILURE
    END

	update dbo.sysmergesubscriptions
		set supportability_mode = 1
	where subid = @subid and pubid = @pubid

    if @@ERROR <> 0
    BEGIN
        GOTO FAILURE
    END

    COMMIT TRAN
    return (0)

FAILURE:
    RAISERROR (20717, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION addmergelogsettings
        COMMIT TRANSACTION
    end
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_addmergelogsettings] TO [public] AS [dbo]
GO
