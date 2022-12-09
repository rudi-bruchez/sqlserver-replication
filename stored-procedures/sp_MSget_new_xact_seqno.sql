SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_new_xact_seqno]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_new_xact_seqno] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_new_xact_seqno]
	@publisher_id [int],
	@publisher_db [sysname],
	@len [tinyint]
WITH EXECUTE AS CALLER
AS
begin
	declare @new_xact_seqno varbinary(16)
	declare @old_xact_seqno varbinary(16)
	declare @tag int
	declare @datalen tinyint
	declare @publisher_database_id int

	set nocount on 
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	select @old_xact_seqno = NULL

	-- Get publisher database id.
	SELECT @publisher_database_id = id from MSpublisher_databases where publisher_id = @publisher_id and 
		publisher_db = @publisher_db

	select TOP(1) @old_xact_seqno = rt.xact_seqno
		from
		-- Prevent inserts
		MSrepl_transactions rt with (HOLDLOCK PAGLOCK UPDLOCK)
		where 
			rt.publisher_database_id = @publisher_database_id 
			order by xact_seqno desc

	if @old_xact_seqno IS NULL
	begin
		/* if nothing got selected, lock the entire table 
		** Don't return meta data !!
		*/
		select @old_xact_seqno = rt.xact_seqno
			from
			MSrepl_transactions rt with (HOLDLOCK TABLOCKX)
			where 0 = 1

		select @old_xact_seqno = subscription_seqno from dbo.MSsubscriptions 
		where
			publisher_database_id = @publisher_database_id and
			subscription_seqno = (select MAX(subscription_seqno) from dbo.MSsubscriptions rs2
			where
				rs2.publisher_database_id = @publisher_database_id)
	end

	select @datalen = datalength(@old_xact_seqno)
	/* Plus one to the tag */
	if @datalen = @len
	begin
		select @tag = convert( int, convert( binary(4), substring( convert( nvarchar, @old_xact_seqno ), @datalen/2 - 2 + 1,2 ) ) )
		
		if @tag = 0xffffffff
		begin
			raiserror(21018, 16, -1)
			return(1)
		end
		/* avoid arithmatic overflow */
		if @tag = 0x7fffffff
			select @tag = 0x80000000
		else 
			select @tag = @tag + 1

		select @new_xact_seqno = 
		convert( varbinary, substring( convert(nvarchar, @old_xact_seqno), 1, @datalen/2-2)) +
		convert( VARBINARY(4), @tag )

	end
	/* Add a tag */
	else
	begin
		if @datalen + 4 <> @len
		begin
			-- We are in trouble if we reach here.
			return(1)
		end
		select @tag = 1
		select @new_xact_seqno = 
			@old_xact_seqno + CONVERT(VARBINARY(4), @tag) 
	end

	select @new_xact_seqno
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_new_xact_seqno] TO [public] AS [dbo]
GO
