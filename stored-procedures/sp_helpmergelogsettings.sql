SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergelogsettings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergelogsettings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergelogsettings]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */

    declare @retcode            int
    declare @pubid                uniqueidentifier
    declare @subid                uniqueidentifier

    IF object_id('sysmergesubscriptions') is NULL
        RETURN (0)
    
    /* Security check */
    EXEC @retcode = sys.sp_MSreplcheck_pull @publication = @publication, 
        @raise_fatal_error = 0
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is defined
    */
    IF @publisher <> '%'
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher
        IF @@ERROR <> 0 OR @retcode <> 0
            RETURN (1)
    END

    /*
    ** Parameter Check:     @subscriber.
    ** If remote server, limit the view to the remote server's subscriptions.
    ** Make sure that the name isn't NULL.
    */
    if @subscriber IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_helpmergelogsettings')
            RETURN (1)
        END

    /*
    ** Parameter Check:     @subscriber.
    ** Check if remote server is defined as a subscription server, and
    ** that the name conforms to the rules for identifiers.
    */

    if @subscriber <> '%'
        BEGIN
            EXECUTE @retcode = sys.sp_validname @subscriber

            if @retcode <> 0 OR @@ERROR <> 0
                RETURN (1)

        END

    /*
    ** Parameter Check:     @publication.
    ** If the publication name is specified, check to make sure that it
    ** conforms to the rules for identifiers and that the publication
    ** actually exists.     Disallow NULL.
    */
    if @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_helpmergelogsettings')
            RETURN (1)
        END

    create table #helplogsettings
                (
                    pubname                      sysname NULL,
                    publisher                    sysname NULL,
                    publisher_db                 sysname NULL,
                    subscriber_server            sysname NULL,
                    db_name                      sysname NULL,
                    web_server                   sysname             NULL,                
                    support_options              int NOT NULL default(0),	-- check the SUPPORT_OPTIONS enum in agent code.
                    log_severity                 int NOT NULL default(2),
                    log_modules                  int NOT NULL default(0),
                    log_file_path                nvarchar(255) NULL,
                    log_file_name                sysname NULL,
                    log_file_size                int NOT NULL default(10000000),
                    no_of_log_files              int NOT NULL default(5),
                    upload_interval              int NOT NULL default(0),
                    delete_after_upload          int NOT NULL default(0),                    
                    custom_script                nvarchar(2000) NULL,
                    message_pattern              nvarchar(2000) NULL,
                    last_log_upload_time         datetime      NULL,
                    agent_xe                      varbinary(max) NULL,
                    agent_xe_ring_buffer    varbinary(max) NULL,
                    sql_xe                          varbinary(max) NULL
                )


    insert into #helplogsettings select distinct pubs.name, pubs.publisher, pubs.publisher_db, subs.subscriber_server, subs.db_name, 
					mss.web_server, mss.support_options, mss.log_severity, mss.log_modules, mss.log_file_path, mss.log_file_name, mss.log_file_size,
					mss.no_of_log_files, mss.upload_interval, mss.delete_after_upload, mss.custom_script, mss.message_pattern, mss.last_log_upload_time,
					agent_xe, agent_xe_ring_buffer, sql_xe

        FROM  dbo.MSmerge_supportability_settings mss,
        	  dbo.sysmergesubscriptions        subs,
              dbo.sysmergepublications    pubs
            where pubs.pubid = subs.pubid
                and subs.pubid <> subs.subid
                and pubs.name =     @publication 
                and mss.subid = subs.subid
                and mss.pubid = subs.pubid
                and ((@subscriber_db = N'%') or (subs.db_name = @subscriber_db collate database_default))
                and ((@publisher_db = N'%') or (pubs.publisher_db = @publisher_db collate database_default))
                and ((@subscriber = N'%') or (UPPER(subs.subscriber_server) = UPPER(@subscriber) collate database_default)) 
                and ((@publisher = N'%') or (UPPER(pubs.publisher) = UPPER(@publisher) collate database_default))
        
	select * from #helplogsettings
	
    drop table #helplogsettings
    return @retcode 
GO
GRANT EXECUTE ON [sys].[sp_helpmergelogsettings] TO [public] AS [dbo]
GO
