SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSactivate_auto_sub]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSactivate_auto_sub] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSactivate_auto_sub]
	@publication [sysname],
	@article [sysname],
	@status [sysname],
	@skipobjectactivation [int],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @retcode		int
	DECLARE	@publisher_type	sysname
	DECLARE @pubid          int
	DECLARE @from_auto_sync	int

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@skipSecurityCheck	= 1
	
	IF @retcode <> 0
		RETURN (@retcode)

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT

    /*
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Check to see if the database has been activated for publication.
    */
    IF sys.fn_MSrepl_istranpublished(DB_NAME(),1) <> 1
    BEGIN
        RAISERROR (14013, 16, -1)
        RETURN (1)
    END

    -- parameter check: @status:  

    IF LOWER(@status collate SQL_Latin1_General_CP1_CS_AS) not in (N'active', N'initiated')
    BEGIN
        RAISERROR(21156, 16, -1)
        RETURN 1
    END

    /*
    ** Parameter Check:  @publication.
    ** Make sure that the publication exists and the publication is not push type
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_MSactivate_auto_sub')
            RETURN (1)
        END

    --
    -- Verify publication exists
    --
	SELECT @pubid = sys.fn_MSrepl_getpubid(@publication, @publisher, @publisher_type)

	IF (@pubid IS NULL)
	BEGIN
		RAISERROR (20026, 11, -1, @publication)
		RETURN (1)
	END
    
    BEGIN TRAN

    IF @status = N'active'
    BEGIN
		UPDATE	syspublications
		SET		immediate_sync_ready = 1 
		WHERE	immediate_sync = 1
		  AND	immediate_sync_ready <> 1
		  AND	pubid = @pubid
		
        IF @@ERROR <> 0
        BEGIN
            GOTO UNDO
            RETURN (1)
        END
    END
    
    SET @from_auto_sync = 1

    EXECUTE @retcode =	sys.sp_changesubstatus 
						@publication = @publication,
						@article = @article,
						@status = @status,
						@from_auto_sync = @from_auto_sync,
						@skipobjectactivation = @skipobjectactivation,
						@publisher = @publisher

    IF @@ERROR <> 0 OR @retcode <> 0
    BEGIN
        GOTO UNDO
        RETURN (1)
    END
    
    COMMIT TRAN
    RETURN(0)

UNDO:
    IF @@TRANCOUNT = 1
        ROLLBACK TRAN
    ELSE
        COMMIT TRAN
END
GO
GRANT EXECUTE ON [sys].[sp_MSactivate_auto_sub] TO [public] AS [dbo]
GO
