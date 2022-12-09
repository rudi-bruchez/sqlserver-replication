SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_log_identity_range_allocations]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_log_identity_range_allocations] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_log_identity_range_allocations]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@is_pub_range [bit],
	@ranges_allocated [tinyint],
	@range_begin [numeric](38, 0),
	@range_end [numeric](38, 0),
	@next_range_begin [numeric](38, 0),
	@next_range_end [numeric](38, 0)
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @retcode tinyint
	declare @max_used numeric(38,0)
	declare @publisher_id int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_MSmerge_log_identity_range_allocation', 'distribution')
		return 1
	end

    select @publisher_id = srvid
        from MSreplservers
        where upper(srvname) = upper(@publisher)
    if @publisher_id is NULL
    begin
        -- Publisher @publisher does not exist.
        raiserror(21618, 16, -1, @publisher)
        return 1
    end

	-- we cannot allocate 0 ranges or call this proc with range_end begin NULL
	if @ranges_allocated = 0 or @ranges_allocated is NULL or @range_end is NULL
	begin
		raiserror(20710, 16, -1, @publisher, @publisher_db, @publication, @article)
		return 1
	end

	if @next_range_end is NULL
		select @max_used = @range_end
	else
		select @max_used = @next_range_end
		
	-- insert the passed in information into the table
	insert into dbo.MSmerge_identity_range_allocations 
		(publisher_id, publisher_db, publication, article, subscriber, subscriber_db, 
		 is_pub_range, ranges_allocated, range_begin, range_end, next_range_begin, next_range_end, max_used)
	values
		(@publisher_id, @publisher_db, @publication, @article, @subscriber, @subscriber_db, 
		 @is_pub_range, @ranges_allocated, @range_begin, @range_end, @next_range_begin, @next_range_end, @max_used)

	if @@error<>0 
		return 1

	return 0
	
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_log_identity_range_allocations] TO [public] AS [dbo]
GO
