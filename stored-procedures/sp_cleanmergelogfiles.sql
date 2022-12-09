SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_cleanmergelogfiles]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_cleanmergelogfiles] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_cleanmergelogfiles]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@web_server [sysname],
	@id [int]
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
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_cleanmergelogfiles')
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
            RAISERROR (14043, 16, -1, '@publication', 'sp_cleanmergelogfiles')
            RETURN (1)
        END

    delete mlf
        FROM  dbo.MSmerge_log_files mlf,
        	  dbo.sysmergesubscriptions        subs,
              dbo.sysmergepublications    pubs
            where ( @id = -1 or @id = mlf.id)
                and pubs.pubid = subs.pubid
                and subs.pubid <> subs.subid
                and pubs.name =     @publication 
                and mlf.subid = subs.subid
                and mlf.pubid = subs.pubid
                and ((@web_server = N'%') or (mlf.web_server = @web_server collate database_default))
                and ((@subscriber_db = N'%') or (subs.db_name = @subscriber_db collate database_default))
                and ((@publisher_db = N'%') or (pubs.publisher_db = @publisher_db collate database_default))
                and ((@subscriber = N'%') or (UPPER(subs.subscriber_server) = UPPER(@subscriber) collate database_default)) 
                and ((@publisher = N'%') or (UPPER(pubs.publisher) = UPPER(@publisher) collate database_default))
        
    return @retcode 
GO
GRANT EXECUTE ON [sys].[sp_cleanmergelogfiles] TO [public] AS [dbo]
GO
