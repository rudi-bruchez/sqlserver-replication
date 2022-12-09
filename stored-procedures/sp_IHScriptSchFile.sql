SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHScriptSchFile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHScriptSchFile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHScriptSchFile]
	@article_id [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode			int
	DECLARE @scriptConstraints	bit
    DECLARE @schemaOption		int
    DECLARE @pubtype			int
    DECLARE @useClustered		bit
    DECLARE @collation          sysname

	SET NOCOUNT ON 

	-- security check, db_owner
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	-- create temp table for command fragments
	create table #proctext
	(
		seq				int identity NOT NULL,
		procedure_text	nvarchar(4000) collate database_default
	)

	-- Get article/publication info
	SELECT	@schemaOption = CONVERT(INT, fn_replprepadbinary8(iha.schema_option)),
			@pubtype = ihp.repl_freq
	FROM	dbo.IHarticles iha,
			dbo.IHpublications ihp
	WHERE	ihp.pubid = iha.publication_id
	  AND	iha.article_id = @article_id

	-- Set script generation flags
	IF ((@schemaOption & 0x10) <> 0)
	BEGIN
		SET @useClustered = 1
	END
	ELSE
	BEGIN
		SET @useClustered = 0
	END

    IF ((@schemaOption & 0x1000) <> 0)
    BEGIN
        -- Get collation of current database (should be distribution)
        -- Convert CI to CS to get case sensitive version of the collation
        SELECT @collation = REPLACE(CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation')), N'_CI_', N'_CS_')
    END
	-- Script objects
	-- Check to see if 0x01 is set for OBJECT CREATION
	IF ((@schemaOption & 0x01) <> 0)
	BEGIN
		-- Script table
		exec @retcode = sys.sp_IHscripttable @article_id, @collation

		IF @retcode != 0
		BEGIN
			set @retcode = 1
			GOTO RETURNSCRIPT
		END
		
		-- Script constraints
		-- Check to see if 0x8000 set for ALTER TABLE syntax
		IF ((@schemaOption & 0x8000) = 0)
		BEGIN
			-- Script primary key constraints
			-- Check to see if 0x80 set for PRIMARY KEY replication
			IF (((@schemaOption & 0x80) <> 0) OR (@pubtype = 0))
			BEGIN
				-- Remove trailing ')' and replace with ','
				update	#proctext
				set		procedure_text = left(procedure_text, len(procedure_text) - 1) + N','
				where 	seq = IDENT_CURRENT('#proctext')

				-- Generate primary key constraints
				exec @retcode = sys.sp_IHscriptprimarykey
									@article_id		= @article_id,
									@useAlterTable	= 0,
									@useClustered	= @useClustered
									
				IF @retcode != 0 OR @@ERROR != 0
				BEGIN
					SET @retcode = 1
					GOTO RETURNSCRIPT
				END
			END

			-- Script unique constraints
			-- Check to see if 0x4000 for UNIQUE CONSTRAINTS
			IF ((@schemaOption & 0x4000) <> 0)
			BEGIN
				-- Remove trailing ')' and replace with ','
				update	#proctext
				set		procedure_text = left(procedure_text, len(procedure_text) - 1) + N','
				where 	seq = IDENT_CURRENT('#proctext')
				
				-- Generate unique constraints
				exec @retcode = sys.sp_IHscriptindexes
									@article_id		= @article_id,
									@useAlterTable	= 0,
									@useUnique		= 1
									
				IF @retcode != 0 OR @@ERROR != 0
				BEGIN
					SET @retcode = 1
					GOTO RETURNSCRIPT
				END
			END
		END
	END
	
RETURNSCRIPT:
	-- Return script fragments
	select	procedure_text
	from	#proctext
	order by seq asc
		
	drop table #proctext

	RETURN @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_IHScriptSchFile] TO [public] AS [dbo]
GO
