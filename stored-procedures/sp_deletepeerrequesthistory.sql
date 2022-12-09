SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_deletepeerrequesthistory]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_deletepeerrequesthistory] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_deletepeerrequesthistory]
	@publication [sysname],
	@request_id [int],
	@cutoff_date [datetime]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode		int,
			@publisher		sysname,
			@publisher_db	sysname

	select @publisher = publishingservername(),
			@publisher_db = db_name()

	-- Publisher Security Check.
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    -- check this db is published
	if sys.fn_MSrepl_istranpublished(db_name(),0) <> 1
    begin
		-- "The database is not published."
		raiserror (18757, 16, -1)
		return 1
	end

	-- parameter checks
	if @request_id is null and @cutoff_date is null
	begin
		-- "The parameter @request_id and @cutoff_date cannot be NULL."
		raiserror (14043, 16, -1, '@request_id and @cutoff_date', 'sp_deletepeerrequesthistory')
        return 1
	end
	else if @request_id is not null and @cutoff_date is not null
	begin
		-- "There must be one and only one of '@request_id' and '@cut_off' that is not NULL."
		raiserror(21314, 16, -1, '@request_id', '@cut_off')
		return 1
	end
	
	-- exit with no error if the tables are not found
	if object_id('MSpeer_request', 'U') is null
		or object_id('MSpeer_response', 'U') is null
	begin
		return 0
	end

	begin transaction
	save transaction tr_delete_peer_request

	if @request_id is not null
	begin
		if not exists(select * 
						from MSpeer_request
						where id = @request_id
							and (publication = @publication
								or @publication is null))
		begin
			-- The @request_id (%d) could not be found for publisher:%s, database:%s, publication:%s.
			raiserror(20688, 16, -1, '@request_id', @request_id, @publisher, @publisher_db, @publication)
			goto UNDO
		end

		delete MSpeer_response
			where request_id = @request_id
		if @@error <> 0 goto UNDO

		delete MSpeer_request
			where id = @request_id
		if @@error <> 0 goto UNDO
	end
	else
	begin
		delete MSpeer_response 
			where request_id in (select id
									from MSpeer_request
									where sent_date <= @cutoff_date
										and (publication = @publication
											or @publication is null))
		if @@error <> 0 goto UNDO

		delete MSpeer_request
			where sent_date <= @cutoff_date
				and (publication = @publication
					or @publication is null)
		if @@error <> 0 goto UNDO
	end

	commit transaction tr_delete_peer_request

	return 0
UNDO:
	rollback transaction tr_delete_peer_request
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_deletepeerrequesthistory] TO [public] AS [dbo]
GO
