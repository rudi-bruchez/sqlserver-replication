SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_originatorid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_originatorid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_originatorid]
	@originator_node [sysname],
	@originator_db [sysname],
	@originator_publication [sysname],
	@originator_publication_id [int],
	@originator_db_version [int],
	@originator_id [int],
	@originator_version [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode bit

	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
	if @@error <> 0 or  @retcode <> 0 
	begin
       	return 1
	end
	
	begin tran 
	save tran tr_sp_MSchange_originatorid

	update dbo.MSpeer_lsns
	set originator_id =	case @originator_id 
						when 0 then NULL
	                                   else @originator_id
					end,
	     originator_version = @originator_version
	where originator = UPPER(@originator_node)
		and originator_db = @originator_db
		and originator_publication	= @originator_publication
		and originator_publication_id = @originator_publication_id
		and originator_db_version	= @originator_db_version

	if @@error <> 0
	begin
		-- The procedure sys.sp_MSchange_originatorid failed to UPDATE the resource MSpeer_lsns. Server error =  @@error.
		raiserror (21499, 16, -1, 'sys.sp_MSchange_originatorid', 'UPDATE', 'MSpeer_lsns', @@error)
		goto FAILURE
       end

	if object_id(N'dbo.MSpeer_originatorid_history') is not NULL
	begin
		if @originator_id is not NULL and @originator_id <> 0 and not exists(select * from dbo.MSpeer_originatorid_history where originator_publication = @originator_publication
																				and originator_id = @originator_id
																				and UPPER(originator_node) = UPPER(@originator_node)
																				and originator_db = @originator_db
																				and originator_db_version = @originator_db_version)
		begin
			insert dbo.MSpeer_originatorid_history
				(originator_publication, originator_id, originator_node, originator_db, originator_db_version, originator_version)
			values(@originator_publication, @originator_id, UPPER(@originator_node), @originator_db, @originator_db_version, @originator_version)

			if @@error <> 0
			begin
				-- The procedure sys.sp_MSchange_originatorid failed to INSERT into the resource MSpeer_originatorid_history. Server error =  @@error.
				raiserror (21499, 16, -1, 'sys.sp_MSchange_originatorid', 'INSERT into', 'MSpeer_originatorid_history', @@error)
				goto FAILURE
			end
		end
	end

	commit tran
	
	return 0

FAILURE:
	
	rollback tran tr_sp_MSchange_originatorid
	commit tran
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_originatorid] TO [public] AS [dbo]
GO
