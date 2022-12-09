SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHarticlecolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHarticlecolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHarticlecolumn]
	@publication [sysname],
	@article [sysname],
	@column [sysname],
	@operation [nvarchar](4),
	@refresh_synctran_procs [bit],
	@ignore_distributor [bit],
	@change_active [int],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@publisher [sysname],
	@publisher_type [sysname],
	@publisher_dbms [sysname],
	@publisher_version [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    declare @article_id			int
    declare @table_id			int
    declare	@publication_type	int
    declare @dest_type_name		sysname
    declare @dest_type			sysname
    declare @dest_length		bigint
    declare @dest_prec			int
    declare @dest_scale			int
    declare @dest_nullable		bit
    declare @dataloss			bit
    declare @src_type			sysname
    declare @src_length			bigint
    declare @src_prec			int
    declare @src_scale			int
    declare @src_nullable       bit
    declare @column_ordinal		int
    declare @publishercolumn_id	int
    declare @retcode			int
    declare @count				int
    declare @artcolumn			sysname
    declare @ispk 				int
	declare @columnid			int
	declare @publisher_id		int

    DECLARE @coldatamap TABLE
    (
        column_name     sysname,
        column_ordinal  int,
        dest_datatype   sysname,
        dest_length     bigint,
        dest_precision  bigint,
        dest_scale      int,
        dest_nullable   bit,
        dataloss        bit
    )

    SET NOCOUNT ON  

	/*
	** Security Check
	*/
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

    /*
    ** Parameter Check:  @publication.
    ** Make sure that the publication exists and that it conforms to the
    ** rules for identifiers.
    */
    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, N'@publication', 'sp_IHarticlecolumn')
            RETURN (1)
        END

    EXECUTE @retcode = dbo.sp_validname @publication

    IF @retcode <> 0
            RETURN (1)

    /*
    ** Parameter Check:  @article.
    ** Check to make sure that the article exists in the publication.
    */

    IF @article IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, N'@article', 'sp_IHarticlecolumn')
        RETURN (1)
    END

    -- Get table ID to improve perf of other calls
    SELECT	@article_id			= a.article_id,
    		@table_id			= a.table_id,
    		@publication_type	= p.publication_type,
    		@publisher_id		= a.publisher_id
    FROM	IHarticles a,
    		MSpublications p,
    		MSreplservers s
    WHERE	a.name				= @article
      AND	p.publication		= @publication
      AND	a.publication_id	= p.publication_id
      AND	a.publisher_id		= s.srvid
      AND	UPPER(s.srvname collate database_default)	= UPPER(@publisher) collate database_default

    IF @table_id IS NULL or @article_id IS NULL
    BEGIN
        RAISERROR(21615, 16, -1, @article)
        RETURN (1)
    END

    /*
    ** Parameter Check:  @operation.
    ** The operation can be either 'add' or 'drop'.
    */
    IF LOWER(@operation) NOT IN (N'add', N'drop')
    BEGIN
        RAISERROR (14019, 16, -1)
        RETURN (1)
    END

    --
    -- Check if there are snapshot or subscriptions and raiserror if needed.
    --
    EXECUTE @retcode  = sys.sp_MSreinit_article @publication                = @publication, 
                                                @article                    = @article,
                                                @need_new_snapshot          = 1,
                                                @need_reinit_subscription   = 1,
                                                @force_invalidate_snapshot	= @force_invalidate_snapshot,
                                                @force_reinit_subscription	= @force_reinit_subscription,
                                                @check_only					= 1,
                                                @publisher					= @publisher,
                                                @publisher_type				= @publisher_type
            
    IF @@ERROR <> 0 OR @retcode <> 0
        return (1)

    --
    -- Column must exist
    --
	IF @column is NOT NULL
    BEGIN
        IF NOT EXISTS
        (
        	SELECT	* 
			FROM	IHpublishercolumns 
			WHERE	table_id = @table_id
			  AND	name = @column
		)
        BEGIN
            RAISERROR(21616, 16, -1, @column, @article)
            RETURN (1)
        END

        IF LOWER(@operation) = N'drop'
        BEGIN
            Declare @isset int
    
            -- Determine column id of column
            SELECT	@columnid = publishercolumn_id 
            FROM	IHcolumns
            WHERE	name = @column
              AND	article_id = @article_id
            
            IF @@error <> 0 OR @columnid IS NULL
            BEGIN
                raiserror(21209, 16, -1, @column)
                return (1)
            END

			-- Primary key column may not be dropped for TRAN publication
			IF @publication_type = 0
			BEGIN
				exec @isset = sys.fn_IHiscolpk @columnid

				if NOT @isset = 0
				BEGIN
					raiserror(21250, 16, -1, @column)
					return (1)
				END
			END
        END -- drop
    
        -- @ignore_distributor is set to 1 when removing replication forcefully. In that
        -- case, no need to check or reinit
            -- Check if there are snapshot or subscriptions and raiserror if needed.
        EXECUTE @retcode  = sys.sp_MSreinit_article
							@publication				= @publication,
							@article					= @article,
							@need_new_snapshot			= 1,
							@need_reinit_subscription	= 1,
							@force_invalidate_snapshot	= @force_invalidate_snapshot,
							@force_reinit_subscription	= @force_reinit_subscription,
							@check_only					= 1,
							@publisher					= @publisher,
							@publisher_type				= @publisher_type

        IF @@ERROR <> 0 OR @retcode <> 0
            return (1)
    END
    
    -- Get default mappings in one shot to improve perf
    -- The cost to get all columns is nearly the same as getting just one.
    -- Error on the side of getting all the columns because this will be a big win in many cases
    IF (@publisher_type LIKE N'ORACLE%')
    BEGIN
        INSERT INTO @coldatamap (column_name, column_ordinal, dest_datatype, dest_length, dest_precision, dest_scale, dest_nullable, dataloss)
        SELECT column_name, column_ordinal, dest_datatype, dest_length, dest_precision, dest_scale, dest_nullable, dataloss
        FROM   sys.fn_ORAenumarticlecolumninfo(@publisher_id, @table_id, @article_id, @publisher_dbms, @publisher_version, 1) colinfo
        ORDER BY colinfo.column_ordinal
    END
    -- FUTURE: Other types should use a similar method
    begin tran
    save TRANSACTION articlecolumn

    IF @column IS NULL
    BEGIN
		DECLARE artcolumn CURSOR LOCAL FAST_FORWARD FOR
		SELECT	ihpc.name,
                ihpc.publishercolumn_id,
                ihpc.column_ordinal,
                ihpc.type,
                cdm.dest_datatype,
                cdm.dest_length,
                cdm.dest_precision,
                cdm.dest_scale,
                cdm.dest_nullable,
                cdm.dataloss
		FROM	IHpublishercolumns ihpc LEFT OUTER JOIN @coldatamap cdm
          ON    ihpc.column_ordinal = cdm.column_ordinal
		WHERE	ihpc.table_id = @table_id
--          AND   ihpc.column_ordinal = cdm.column_ordinal
		ORDER BY ihpc.column_ordinal
    END
    ELSE
    BEGIN
        DECLARE artcolumn CURSOR LOCAL FAST_FORWARD FOR
        SELECT	ihpc.name,
                ihpc.publishercolumn_id,
                ihpc.column_ordinal,
                ihpc.type,
                cdm.dest_datatype,
                cdm.dest_length,
                cdm.dest_precision,
                cdm.dest_scale,
                cdm.dest_nullable,
                cdm.dataloss
        FROM	IHpublishercolumns ihpc,
                @coldatamap cdm
        WHERE	ihpc.table_id = @table_id
          AND   ihpc.column_ordinal = cdm.column_ordinal
          AND   ihpc.name = @column
        ORDER BY ihpc.column_ordinal
    END

    OPEN artcolumn

    WHILE (1=1)
    BEGIN
        FETCH   artcolumn
        INTO    @artcolumn,
                @publishercolumn_id,
                @column_ordinal,
                @src_type,
                @dest_type_name,
                @dest_length,
                @dest_prec,
                @dest_scale,
                @dest_nullable,
                @dataloss

        IF @@fetch_status <> 0
            BREAK

        IF LOWER(@operation) = 'add'
        BEGIN       
            -- Check if this column is already published, if it is silently ignore it
            IF EXISTS
            (
				SELECT	*
				FROM	IHcolumns
				WHERE	article_id = @article_id
				  AND   name = @artcolumn
			)
            BEGIN
                CONTINUE
            END

            -- Check if data type is publishable
			IF (sys.fn_MSrepl_checktype(@src_type, @publisher_dbms, @publisher_version) = 0)
			BEGIN
				RAISERROR(21669, 10, -1, @artcolumn, @src_type)
				CONTINUE
			END

			-- Get core type (necessary due to varchar(max) cases)
			IF UPPER(RIGHT(@dest_type_name, 5)) = N'(MAX)'
			BEGIN
				SELECT @dest_type_name = LEFT(@dest_type_name, LEN(@dest_type_name) - 5)
				SELECT @dest_length = -1
			END

			-- Get systype id for destination data type
			SELECT	@dest_type = type_id(@dest_type_name)
			
			IF @dest_type IS NULL
			BEGIN
	    		RAISERROR(21779, 16, -1, @src_type)
			
				IF @@trancount > 0
				BEGIN
					ROLLBACK TRANSACTION articlecolumn
					COMMIT TRAN
				END
				RETURN (1)
			END
    
            -- Insert the column to mark it as being published for this article
            INSERT IHcolumns
            (
				name,
				publishercolumn_id,
				article_id,
				column_ordinal,
				mapped_type,
				mapped_length,
				mapped_prec,
				mapped_scale,
				mapped_nullable
			)
            VALUES
            (
				@artcolumn,
				@publishercolumn_id,
				@article_id,
				@column_ordinal,
				@dest_type,
				@dest_length,
				@dest_prec,
				@dest_scale,
				@dest_nullable
			)
    
            IF @@ERROR <> 0
            BEGIN
                if @@trancount > 0
                begin
                    ROLLBACK TRANSACTION articlecolumn
                    commit tran
                end
                RETURN (1)
            END
        END
        ELSE
        BEGIN -- operation is 'delete'
			-- Error if column to drop is a primary key on a TRAN pub
			IF @publication_type = 0
			BEGIN
				EXEC @ispk = sys.fn_IHiscolpk @publishercolumn_id
				IF @ispk = 1
				BEGIN
					RAISERROR (21250, 16, -1, @column)
					IF @@trancount > 0
					BEGIN
						ROLLBACK TRANSACTION articlecolumn
						COMMIT TRAN
					END

					RETURN (1)
				END
			END
            
            -- Remove the column from the article
            DELETE FROM IHcolumns
            WHERE article_id = @article_id
            AND   name = @artcolumn
            
            IF @@ERROR <> 0
            BEGIN
                if @@trancount > 0
                begin
                    ROLLBACK TRANSACTION articlecolumn
                    commit tran
                end
                RETURN (1)
            END

        END
    END -- WHILE
    
    -- Update distributor timestamp to reflect change in meta data	
	EXEC @retcode = sys.sp_IHreplflush	@publisher

	IF @retcode != 0 OR @@ERROR != 0
    BEGIN
        if @@trancount > 0
        begin
            ROLLBACK TRANSACTION articlecolumn
            commit tran
        end
        RETURN (1)
    END

    -- Set publisher_status to 0 to indicate
    -- that a call to sp_articleview is needed
    -- to complete the article definition.
    UPDATE	dbo.IHarticles
    SET		publisher_status	= 0
    WHERE	article_id			= @article_id
    AND    	table_id			= @table_id

    IF @@ERROR <> 0
    BEGIN
        if @@trancount > 0
        begin
            ROLLBACK TRANSACTION articlecolumn
            commit tran
        end
        RETURN (1)
    END

    -- Have to call this stored procedure to invalidate existing snapshot or reint
    -- subscriptions if needed
    EXECUTE @retcode  = sys.sp_MSreinit_article
						@publication				= @publication, 
						@article					= @article,
						@need_new_snapshot			= 1,
						@need_reinit_subscription	= 1,
						@force_invalidate_snapshot	= @force_invalidate_snapshot,
						@force_reinit_subscription	= @force_reinit_subscription,
						@publisher					= @publisher,
						@publisher_type				= @publisher_type

    IF @@ERROR <> 0 OR @retcode <> 0
    BEGIN
		IF @@trancount > 0
		BEGIN
			ROLLBACK TRANSACTION articlecolumn
			COMMIT TRAN
		END

        RETURN (1)
	END

    COMMIT TRAN
END
GO
GRANT EXECUTE ON [sys].[sp_IHarticlecolumn] TO [public] AS [dbo]
GO
