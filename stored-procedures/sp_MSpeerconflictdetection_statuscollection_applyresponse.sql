SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerconflictdetection_statuscollection_applyresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerconflictdetection_statuscollection_applyresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerconflictdetection_statuscollection_applyresponse]
	@request_id [int],
	@peer_node [sysname],
	@peer_db [sysname],
	@peer_db_version [int],
	@conflictdetection_enabled [bit],
	@peer_originator_id [int],
	@peer_conflict_retention [int],
	@peer_continue_onconflict [bit],
	@peer_histids [nvarchar](max),
	@originator_node [sysname],
	@originator_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	-- security check - should be dbo or sysadmin
	declare @retcode int
	exec @retcode = sp_MSreplcheck_subscribe
	if @@ERROR != 0 or @retcode != 0
		return
	
	if sys.fn_MSrepl_istranpublished(db_name(), 1) <> 1
		return

	if publishingservername() <> @originator_node or db_name() <> @originator_db
		return

	declare @publication sysname
	select @publication  = publication
	from MSpeer_conflictdetectionconfigrequest 
	where id = @request_id

	if @publication is NULL  --request does not exists
		return;

	begin tran
	save tran tr_statuscollection_applyresp
	
	update MSpeer_conflictdetectionconfigresponse
	set	peer_db_version = @peer_db_version,
		conflictdetection_enabled = @conflictdetection_enabled,
		originator_id = @peer_originator_id,
		peer_conflict_retention = @peer_conflict_retention,
		peer_continue_onconflict = @peer_continue_onconflict,
		progress_phase = N'status collected',
		modified_date = GETDATE()
	where request_id = @request_id
		and peer_node = @peer_node
		and peer_db = @peer_db
		and progress_phase = N'peer version collected'
	if @@error <> 0
		goto UNDO
	
       --incorporate historical originator IDs into MSpeer_originatorid_history
       --@peer_histids contains the root : /peer_histids
	declare @DocHandle int
	exec sp_xml_preparedocument @DocHandle OUTPUT, @peer_histids
	if @@error <> 0
		goto UNDO
	
	insert MSpeer_originatorid_history (originator_publication, originator_id, originator_node, originator_db,  originator_db_version, originator_version)
	select @publication, originator_id, originator_node, originator_db, originator_db_version, originator_version
	from (	select  *
	 		from OPENXML (@DocHandle, N'/peer_histids/histid', 1)
	 		with (originator_id int,  originator_node sysname,  originator_db sysname,  originator_db_version int, originator_version int)
	 	) as A
	where not exists (select * from MSpeer_originatorid_history
	 				where originator_publication = @publication and originator_id = A.originator_id 
	 					and originator_node = A.originator_node and originator_db = A.originator_db
	 					and originator_db_version = A.originator_db_version)
	
	if @@error <> 0
		goto UNDO

	exec sp_xml_removedocument @DocHandle
	if @@error <> 0
		goto UNDO

	commit tran
	return

UNDO:
	rollback tran tr_statuscollection_applyres
	commit tran
	return

end
GO
GRANT EXECUTE ON [sys].[sp_MSpeerconflictdetection_statuscollection_applyresponse] TO [public] AS [dbo]
GO
