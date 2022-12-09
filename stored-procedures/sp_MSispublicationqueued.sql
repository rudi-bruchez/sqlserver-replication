SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSispublicationqueued]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSispublicationqueued] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSispublicationqueued]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@allow_queued_tran [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- get the queued tran state for the publication
	--
	if object_id(N'MSpublications') is not NULL
	begin
		select @allow_queued_tran = pub.allow_queued_tran 
		from (dbo.MSpublications as pub join MSreplservers as srv
				on pub.publisher_id = srv.srvid)
		where UPPER(srv.srvname) = UPPER(@publisher)
			and pub.publisher_db = @publisher_db
			and pub.publication = @publication
	end
	else
		select @allow_queued_tran = 0

	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSispublicationqueued] TO [public] AS [dbo]
GO
