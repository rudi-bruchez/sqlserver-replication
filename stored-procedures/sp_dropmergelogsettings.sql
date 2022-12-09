SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergelogsettings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergelogsettings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergelogsettings]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@web_server [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode                int
    declare @pubid                    uniqueidentifier
    declare @subid                    uniqueidentifier
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
            RAISERROR (14043, 16, -1, '@publication', 'sp_dropmergelogsettings')
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
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_dropmergelogsettings')
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
	    RAISERROR (20720, 16, -1, @subscriber, @subscriber_db,@web_server)
        RETURN(1)
    end                    			       

    begin tran
    save TRAN dropmergelogsettings

    delete dbo.MSmerge_supportability_settings 
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

    COMMIT TRAN
    return (0)

FAILURE:
    RAISERROR (20721, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION dropmergelogsettings
        COMMIT TRANSACTION
    end
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergelogsettings] TO [public] AS [dbo]
GO
