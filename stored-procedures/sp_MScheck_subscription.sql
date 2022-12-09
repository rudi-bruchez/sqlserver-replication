SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_subscription]
	@publication [sysname],
	@pub_type [int],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	declare	@publisher_type sysname,
			@merge_pubid    uniqueidentifier,
			@tran_pubid     int,
			@result         int,
			@retcode        int

	-- Initialize
	SET @result = 0

    --
    -- Security Check.
    --
    IF IS_MEMBER('db_owner') <> 1 
    	AND IS_MEMBER('replmonitor') <> 1
	BEGIN
		SELECT 0
    	RETURN 0
	END

	-- Check to see if database is activated for publication
    IF sys.fn_MSrepl_ispublished(DB_NAME()) <> 1
    BEGIN
        RAISERROR (14013, 16, -1)
        RETURN (1)
    END

    -- Get publisher info
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo  @publisher		= @publisher,
                                                      @publisher_type   = @publisher_type OUTPUT
    IF @@error <> 0
    BEGIN
         RAISERROR (14071, 16, -1)
         RETURN (1)
    END

	IF @pub_type = 2
	BEGIN
		IF @publisher_type != N'MSSQLSERVER'
		BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
		
		-- Merge publications
	    IF OBJECT_ID('sysmergepublications', 'U') IS NULL
	    BEGIN
	        RAISERROR(20054, 16, -1)
	        RETURN (1)
	    END
	    
	    SELECT	@merge_pubid = pubid
	    FROM	dbo.sysmergepublications
	    WHERE	name = @publication
	      AND	publisher = publishingservername()
	      AND	publisher_db = db_name()

	    IF @merge_pubid IS NULL
	    BEGIN
	        RAISERROR(20026, 16, -1, @publication)
	        RETURN (1)
	    END
	    
	    IF EXISTS
	    (
	    	SELECT	*
	    	FROM	dbo.sysmergesubscriptions
	    	WHERE	pubid = @merge_pubid
	    	  AND	subid != pubid
	    )
	    BEGIN
	        SET @result = 1
	    END
	END
	ELSE
	BEGIN
		--
	    -- If not merge, it has to be tran level.
	    -- For other level, a generic error will be returned.
	    --
	    
	    IF OBJECT_ID('syspublications', 'U') IS NULL AND OBJECT_ID('syspublications', 'V') IS NULL
	    BEGIN
	        RAISERROR(20054, 16, -1)
	        RETURN (1)
	    END

		-- Get publication id
		SELECT @tran_pubid = sys.fn_MSrepl_getpubid(@publication, @publisher, @publisher_type)

	    IF @tran_pubid IS NULL 
	    BEGIN
	        RAISERROR(20026, 16, -1, @publication)
	        RETURN (1)
	    END
	    
	    IF EXISTS
	    (
	    	SELECT	*
	    	FROM	syssubscriptions
	    	WHERE	srvid != -1
	    	  AND	artid IN 
	                (
	                	SELECT	artid
	                	FROM	sysextendedarticlesview
	                	WHERE	pubid = @tran_pubid
	                )
		)
		BEGIN
			SET @result = 1
		END
	END

	SELECT @result
	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MScheck_subscription] TO [public] AS [dbo]
GO
