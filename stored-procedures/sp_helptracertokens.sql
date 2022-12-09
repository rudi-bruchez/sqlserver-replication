SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helptracertokens]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helptracertokens] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helptracertokens]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 			int,
			@distproc 			nvarchar(1000),
			@distributor 		sysname, 
			@distribution_db 	sysname
	--
	-- Calling convention is different if we are already at the distdb
	--
	if sys.fn_MSrepl_isdistdb (db_name()) = 1
	begin
		-- security check for distributor is performed in the helper proc.
	
		-- if we are at the distributor then publisher and
		-- publisher db are required parameters for this proc
		if isnull(@publisher, N'') = N''
		begin
			-- Parameter '%s' cannot be NULL or empty string when this procedure is run from a distribution database.
			raiserror(20686, 16, -1, '@publisher', 'distribution')
			return 1
		end
		else if isnull(@publisher_db, N'') = N''
		begin
			-- Parameter '%s' cannot be NULL or empty string when this procedure is run from a distribution database.
			raiserror(20686, 16, -1, '@publisher_db', 'distribution')
			return 1
		end
		
		exec @retcode = sys.sp_MShelptracertokens @publication 		= @publication,
													@publisher		= @publisher,	
													@publisher_db	= @publisher_db
		
		return @retcode
	end

	--
	-- Everything below this line is expected to run on the Publisher
	--

	-- Publisher Security Check.
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    -- check this db is published
	if sys.fn_MSrepl_istranpublished(db_name(),1) <> 1
    begin
		-- "The database is not published."
		raiserror (18757, 16, -1)
		return 1
	end
	
	-- do not allow users to specify pub/pubdb unless at disdb
	if @publisher is not NULL
	begin
		-- Parameter ''%s'' must be NULL when this procedure is not being run from a distribution database.
		raiserror(20687, 16, -1, '@publisher', 'distribution')
		return 1
	end
	else if @publisher_db is not NULL
	begin
		-- Parameter ''%s'' must be NULL when this procedure is not being run from a distribution database.
		raiserror(20687, 16, -1, '@publisher_db', 'distribution')
		return 1
	end

	select @publisher = publishingservername(),
			@publisher_db = db_name()

	exec @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT, 
											@distribdb = @distribution_db OUTPUT,
											@publisher = @publisher
	if @@error <> 0 or @retcode <> 0 or @distributor is NULL
	begin
		-- "The Distributor has not been installed correctly."
		raiserror(20036, 16, -1)
		return 1
	end

	select @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MShelptracertokens'	
	exec @retcode = @distproc @publication 		= @publication,
								@publisher		= @publisher,	
								@publisher_db	= @publisher_db
	if @@error <> 0 or @retcode <> 0 
	begin
		return 1
	end

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_helptracertokens] TO [public] AS [dbo]
GO
