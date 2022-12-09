SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerconflictdetection_statuscollection_sendresponse]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerconflictdetection_statuscollection_sendresponse] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerconflictdetection_statuscollection_sendresponse]
	@request_id [int],
	@publication [sysname],
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
		return -- not tran published

	declare	@peer_node	sysname, 
			@peer_db	sysname,
			@peer_db_version int,
			@options int, 
			@conflictdetection_enabled bit,
			@peer_originator_id	int,
			@peer_conflict_retention int,
			@peer_continue_onconflict bit,
			@peer_histids nvarchar(max), --content of MSpeer_originatorid_history in xml format
			@OPT_ENABLED_FOR_P2P int,
			@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION int,
			@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT int,
			@cmdtxt nvarchar(max)


	select 	@OPT_ENABLED_FOR_P2P = 0x1,
			@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION = 0x8,
			@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT = 0x10

	select	@options = options, 
			@peer_originator_id = originator_id,
			@peer_conflict_retention = conflict_retention
	from syspublications
	where name = @publication

	if (@options is NULL or @options & @OPT_ENABLED_FOR_P2P <> @OPT_ENABLED_FOR_P2P)
		return -- not a p2p publication
	
	select @peer_node = publishingservername()
	select @peer_db = db_name()

	exec @retcode = sys.sp_MSgetdbversion @current_version = @peer_db_version output
	if @@error <> 0 or @retcode <> 0
		return
		
	if (@options & @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION = @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION)
	begin
		select @conflictdetection_enabled = 1

		if (@options & @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT = @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT)
			select @peer_continue_onconflict  = 1
		else
			select @peer_continue_onconflict  = 0
	end
	else
	begin
		select	@conflictdetection_enabled = 0,
				@peer_originator_id = NULL,
				@peer_conflict_retention = NULL,
				@peer_continue_onconflict = NULL
	end


	-- obtain histids
	declare @histidtab table (originator_id int,  originator_node sysname,  originator_db sysname,  originator_db_version int, originator_version int)
	insert  @histidtab
		select	originator_id,  originator_node, originator_db,  originator_db_version, originator_version
		from 	MSpeer_originatorid_history
		where	originator_publication = @publication
	if @@error <> 0
		return
	
	select @peer_histids = convert(nvarchar(max), (select * from @histidtab as histid for XML auto))
	if @@error <> 0
		return
		
	--add root: /peer_histids
	select @peer_histids = N'<peer_histids>' + @peer_histids + N'</peer_histids>' 


	-- construct the command to be forwarded
	select @cmdtxt = N'if @@microsoftversion >= 0x0A000000 
					begin
						exec sp_MSpeerconflictdetection_statuscollection_applyresponse 
							@request_id =' + cast(@request_id as nvarchar) + N',
							@peer_node = N' + QUOTENAME(@peer_node, N'''') + N',
							@peer_db = N' + QUOTENAME(@peer_db, N'''') + N',
							@peer_db_version = ' + cast(@peer_db_version as nvarchar) + N',
							@conflictdetection_enabled = ' + cast(@conflictdetection_enabled as nvarchar) + N',
							@peer_originator_id = '
							
	if @peer_originator_id is NULL
			select @cmdtxt = @cmdtxt + N'NULL,'
	else
			select @cmdtxt = @cmdtxt + cast(@peer_originator_id as nvarchar) + N','

	select @cmdtxt = @cmdtxt + N'@peer_conflict_retention = '
			
	if @peer_conflict_retention is NULL
			select @cmdtxt = @cmdtxt + N'NULL,'
	else
			select @cmdtxt = @cmdtxt + cast(@peer_conflict_retention as nvarchar) + N','							

	select @cmdtxt = @cmdtxt + N'@peer_continue_onconflict = '

	if @peer_continue_onconflict is NULL
			select @cmdtxt = @cmdtxt + N'NULL,'
	else
			select @cmdtxt = @cmdtxt + cast(@peer_continue_onconflict as nvarchar) + N','							
														
	select @cmdtxt = @cmdtxt + N'@peer_histids = N''' +  REPLACE(@peer_histids, N'''', N'''''') + N''', 
							@originator_node = N' + QUOTENAME(@originator_node, N'''') + N', 
							@originator_db = N' + QUOTENAME(@originator_db, N'''') + N'
					end'

	-- forward the command to apply response
	exec sys.sp_MSpeertopeerfwdingexec @command = @cmdtxt, @publication = @publication

	return
end 
GO
GRANT EXECUTE ON [sys].[sp_MSpeerconflictdetection_statuscollection_sendresponse] TO [public] AS [dbo]
GO
