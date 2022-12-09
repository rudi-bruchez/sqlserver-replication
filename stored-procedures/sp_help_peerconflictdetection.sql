SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_help_peerconflictdetection]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_help_peerconflictdetection] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_help_peerconflictdetection]
	@publication [sysname],
	@timeout [int]
WITH EXECUTE AS CALLER
AS
begin
	set NOCOUNT on

	declare @retcode int
		,@pubid int
		,@options int
		,@OPT_ENABLED_FOR_P2P int
		,@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION int
		,@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT int
		,@originator_node	sysname
		,@originator_version int
		,@originator_db sysname
		,@originator_db_version int
		,@originator_id int
		,@conflict_retention int
		,@continue_onconflict bit
		,@subscriptions xml
		,@sub_srvname sysname
		,@sub_db sysname
		,@request_id int
		,@conflictdetection_enabled bit
		,@elapsetime int --in seconds
		,@phase_timed_out bit
		,@cursor_allocated bit
		,@cursor_opened bit


	select @OPT_ENABLED_FOR_P2P = 0x1
		,@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION = 0x8
		,@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT = 0x10
		,@originator_version = @@microsoftversion
		,@originator_db = db_name()
		,@cursor_allocated = 0
		,@cursor_opened = 0

            
	--Security Check

	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
		return(1)

	-- Check to see if the database has been activated for publication.

	if sys.fn_MSrepl_istranpublished(@originator_db, 1) <> 1
	begin
		raiserror (14013, 16, -1)
		return (1)
	end

	-- Parameter Check: @publication.
	-- The @publication name cannot be NULL and must conform to the rules
	-- for identifiers.

	if @publication is NULL
	begin
		raiserror (14043, 16, -1, N'@publication', N'sp_help_peerconflictdetection')
		return (1)
	end

	execute @retcode = sys.sp_validname @publication
	if @retcode <> 0
		return (1)
        
	select @pubid = pubid, @options = options, @originator_id = originator_id, @conflict_retention = conflict_retention
	from syspublications
	where name = @publication

	if @pubid is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1) 
	end

	select @originator_node = publishingservername()

	if (@options & @OPT_ENABLED_FOR_P2P) <> @OPT_ENABLED_FOR_P2P
	begin
		raiserror (22808, 16, -1, @publication, N'sp_help_peerconflictdetection')
		return (1)
	end

	-- parameter check: @timeout
	if @timeout <= 0
	begin
		raiserror (22811, 16, -1)
		return (1)
	end 

	-- this procedure can not be executed in a user
	-- transaction because it needs to be in its own tran
	-- space (it can not be mixed with replicated cmds).
	--
	-- we use this tmp table insert to force any implicit
	-- transaction (user may set IMPLICIT_TRANSACTIONS on)
	declare @check_tran table(col1 int)
	insert into @check_tran(col1) values (1)
	
	if @@trancount > 0
	begin
		-- The procedure 'sp_help_peerconflictdetection' cannot be executed within a transaction.
		raiserror(15002, 16, -1, 'sp_help_peerconflictdetection')
		return (1)
	end

	if (@options & @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION) = @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION
	begin
		select @conflictdetection_enabled = 1
		
		if (@options & @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT) = @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT
			select @continue_onconflict = 1
		else
			select @continue_onconflict = 0
	end
	else
	begin
		select @conflictdetection_enabled = 0
		select @originator_id = NULL
		select @conflict_retention = NULL
		select @continue_onconflict = NULL
	end

	exec @retcode = sys.sp_MSgetdbversion @current_version = @originator_db_version output
	if @@error <> 0 or @retcode <> 0
	begin
		raiserror(21542, 16, 1, @@error, 'sp_MSgetdbversion')	
		return (1)
	end

	-- begin transaction
	begin tran
	save tran tr_sp_help_peerconflictdetection

	-- obtain subscriptions
	declare @peersubtab table (sub_node sysname, sub_db sysname)
	insert 	@peersubtab
		select	distinct A.srvname, A.dest_db
		from 	syssubscriptions A join sysarticles B on A.artid = B.artid
		where	B.pubid = @pubid and A.srvid <> -1
	if @@error <> 0
		goto UNDO
	
	select @subscriptions = (select * from @peersubtab as sub for XML auto)
	if @@error <> 0
		goto UNDO

	select @subscriptions = convert(xml, N'<peer_subs>' + convert(nvarchar(max), @subscriptions) + N'</peer_subs>') 

	-- in order to obtain the result in relational form, run the following statements
	-- 	declare @DocHandle int
	-- 	exec sp_xml_preparedocument @DocHandle OUTPUT, convert(nvarchar(max), @subscriptions)
	-- 	select  *
	-- 	from OPENXML (@DocHandle, N'/peer_subs/sub', 1)
	-- 	with (sub_node sysname, sub_db sysname)
	-- 	exec sp_xml_removedocument @DocHandle

	--delete existing requests and responses
	delete from MSpeer_conflictdetectionconfigrequest
	if @@error <> 0
		goto UNDO
		
	delete from MSpeer_conflictdetectionconfigresponse
	if @@error <> 0
		goto UNDO

	--new a request
	insert MSpeer_conflictdetectionconfigrequest (publication, timeout, progress_phase, phase_timed_out)
	values(@publication, @timeout, N'started', 0)
	if @@error <> 0
		goto UNDO

	select @request_id =MAX(id) 
	from MSpeer_conflictdetectionconfigrequest

	--insert the response from local peer
	insert MSpeer_conflictdetectionconfigresponse (request_id, peer_node, peer_db, peer_version, peer_db_version,
       	     is_peer, conflictdetection_enabled, originator_id, peer_conflict_retention, peer_continue_onconflict, peer_subscriptions, progress_phase)
	values (@request_id, @originator_node, @originator_db, @originator_version, @originator_db_version, 1 /*is_peer*/, 
	            @conflictdetection_enabled, @originator_id, @conflict_retention, @continue_onconflict, @subscriptions, N'status collected')
	if @@error <> 0
		goto UNDO

	-- insert sub entries of this peer
	insert MSpeer_conflictdetectionconfigresponse (request_id, peer_node, peer_db, progress_phase)
		select @request_id, sub_node, sub_db, N'started'
		from @peersubtab
	if @@error <> 0
		goto UNDO

	commit tran

	raiserror (22817, 10, -1, N'Scanning topology', N'started') with nowait 
	
	--starting first round: topology exploring
	update MSpeer_conflictdetectionconfigrequest
	set 	progress_phase = N'exploring topology',
		modified_date = GETDATE()
	where id = @request_id
	
	exec sp_MSpeerconflictdetection_topology_sendrequest @request_id, @publication
	if @@error <> 0
		return (1)

	select @elapsetime = 0
	while (@elapsetime < @timeout)
	begin
		waitfor delay '00:00:01'   -- 1 second 
		select @elapsetime = @elapsetime + 1
		
		if exists(select * from MSpeer_conflictdetectionconfigresponse
				where request_id = @request_id and is_peer is null)
			continue
		else
			break
	end


	if @elapsetime >= @timeout
	begin
		raiserror(22812, 10, -1, N'exploring topology', @timeout) with nowait -- raise a warning

		update MSpeer_conflictdetectionconfigrequest
		set 	phase_timed_out = 1,
			modified_date = GETDATE()
		where id = @request_id
	end

	raiserror (22817, 10, -1, N'Scanning topology', N'ended') with nowait 
	raiserror (22817, 10, -1, N'Status collection', N'started') with nowait 

	--starting second round: status collecting
	update MSpeer_conflictdetectionconfigrequest
	set 	progress_phase = N'collecting status',
		modified_date = GETDATE()
	where id = @request_id

	exec sp_MSpeerconflictdetection_statuscollection_sendrequest @request_id, @publication
	if @@error <> 0
		return (1)

	select @elapsetime = 0
	while (@elapsetime < @timeout)
	begin
		waitfor delay '00:00:01'   -- 1 second 
		select @elapsetime = @elapsetime + 1
		
		if exists(select * from MSpeer_conflictdetectionconfigresponse
				where request_id = @request_id 
					and (is_peer is NULL or progress_phase <> N'status collected'))
			continue
		else
			break
	end

	if @elapsetime >= @timeout
	begin
		raiserror(22812, 10, -1, N'collecting status', @timeout) with nowait -- raise a warning
		select @phase_timed_out = 1
	end
	else
		select @phase_timed_out = 0

	update MSpeer_conflictdetectionconfigrequest
	set 	progress_phase = N'status collected',
		phase_timed_out = @phase_timed_out,
		modified_date = GETDATE()
	where id = @request_id
	if @@error <> 0
		return (1)

	raiserror (22817, 10, -1, N'Status collection', N'ended') with nowait 

	--status report
	if exists(select * from MSpeer_conflictdetectionconfigresponse 
			where peer_version < 0x0A000000)
	begin
		-- peers earlier than Katmail exist
		raiserror(22813, 10, -1) with nowait 
	end
	
	if 	(select count (distinct originator_id)
		from MSpeer_originatorid_history
		where originator_publication = @publication)
	 < 	(select count (originator_id)
		 from MSpeer_originatorid_history
		 where originator_publication = @publication)
	begin 
		-- duplicate peer IDs are found
		raiserror(22814, 10, -1) with nowait 
	end

	select * from MSpeer_conflictdetectionconfigrequest
	select * from MSpeer_conflictdetectionconfigresponse
	select * from MSpeer_originatorid_history
	
	return (0)
	
UNDO:
	rollback tran tr_sp_help_peerconflictdetection
	commit tran
	return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_help_peerconflictdetection] TO [public] AS [dbo]
GO
