SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerconflictdetection_topology_applyresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerconflictdetection_topology_applyresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerconflictdetection_topology_applyresponse]
	@request_id [int],
	@peer_node [sysname],
	@peer_db [sysname],
	@peer_version [int],
	@peer_subscriptions [nvarchar](max)
WITH EXECUTE AS CALLER
AS
begin

	-- security check - should be dbo or sysadmin
	declare @retcode int
	exec @retcode = sp_MSreplcheck_subscribe
	if @@ERROR != 0 or @retcode != 0
		return

	if not exists (select * from MSpeer_conflictdetectionconfigrequest where id = @request_id) --request does not exists
		return

	begin tran 
	save tran tr_topology_applyresponse

	--@peer_subscriptions is extended to contain the root: /peer_subs
       select @peer_subscriptions = N'<peer_subs>' + @peer_subscriptions + N'</peer_subs>' 
	
	begin try
		insert MSpeer_conflictdetectionconfigresponse (request_id, peer_node, peer_db, peer_version, is_peer, peer_subscriptions, progress_phase)
		values (@request_id, @peer_node, @peer_db, @peer_version, 1, convert(xml, @peer_subscriptions), N'peer version collected')
	end try
	begin catch
       	if @@error in (2627, 2601)  ---primary key/unique violation
       	begin
      			update MSpeer_conflictdetectionconfigresponse
			set	peer_version = @peer_version,
				is_peer = 1,
				peer_subscriptions = @peer_subscriptions,
				progress_phase = N'peer version collected',
				modified_date = GETDATE()
			where request_id = @request_id
				and peer_node = @peer_node
				and peer_db = @peer_db
				and progress_phase = N'started'
				
			if @@error <> 0
				goto UNDO
       	end
       	else
       		goto UNDO
       end catch

       --incorporate subscribers into MSpeer_conflictdetectionconfigresponse
	declare @DocHandle int
	exec sp_xml_preparedocument @DocHandle OUTPUT, @peer_subscriptions
	if @@error <> 0
		goto UNDO
	
	insert MSpeer_conflictdetectionconfigresponse (request_id, peer_node, peer_db, progress_phase)
	select @request_id, sub_node, sub_db, N'started'
	from (	select  *
	 		from OPENXML (@DocHandle, N'/peer_subs/sub', 1)
	 		with (sub_node sysname, sub_db sysname)
	 	) A
	 where not exists (select * from MSpeer_conflictdetectionconfigresponse
	 				where request_id = @request_id and peer_node = A.sub_node and peer_db = A.sub_db)
	
	if @@error <> 0
		goto UNDO

	exec sp_xml_removedocument @DocHandle
	if @@error <> 0
		goto UNDO

       commit tran
       return 

UNDO:
	rollback tran tr_topology_applyresponse
	commit tran
	return
end 
GO
GRANT EXECUTE ON [sys].[sp_MSpeerconflictdetection_topology_applyresponse] TO [public] AS [dbo]
GO
