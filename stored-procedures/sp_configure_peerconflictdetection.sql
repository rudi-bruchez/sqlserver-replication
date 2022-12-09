SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_configure_peerconflictdetection]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_configure_peerconflictdetection] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_configure_peerconflictdetection]
	@publication [sysname],
	@action [nvarchar](32),
	@originator_id [int],
	@conflict_retention [int],
	@continue_onconflict [nvarchar](5),
	@local [nvarchar](5),
	@timeout [int]
WITH EXECUTE AS CALLER
AS
begin
	set NOCOUNT on

	declare @retcode int
		,@db_name   sysname
		,@pubid int
		,@options int
		,@OPT_ENABLED_FOR_P2P int = 0x1
		,@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION int = 0x8
		,@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT int = 0x10
		,@enabling bit
		,@peercmdtxt nvarchar(max)
		,@artid int
		,@current_db_version int
		,@strval nvarchar(32)
		
	select @db_name=db_name()
            
	--Security Check

	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
		return(1)

	-- Check to see if the database has been activated for publication.

	if sys.fn_MSrepl_istranpublished(@db_name, 1) <> 1
	begin
		raiserror (14013, 16, -1)
		return (1)
	end

	-- Parameter Check: @publication.
	-- The @publication name cannot be NULL and must conform to the rules
	-- for identifiers.

	if @publication is NULL
	begin
		raiserror (14043, 16, -1, N'@publication', N'sp_configure_peerconflictdetection')
		return (1)
	end

	execute @retcode = sys.sp_validname @publication
	if @retcode <> 0
		return (1)
        

	select @pubid = pubid, @options = options
	from syspublications
	where name = @publication

	if @pubid is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1) 
	end

	if (@options & @OPT_ENABLED_FOR_P2P) <> @OPT_ENABLED_FOR_P2P
	begin
		raiserror (22808, 16, -1, N'sp_configure_peerconflictdetection', @publication)
		return (1)
	end

	-- parameter check: @local
	if (LOWER(@local) not in (N'true', N'false'))
	begin
		raiserror (14148, 16, -1, N'@local')
		return (1)
	end
	select @local = LOWER(@local)


	if @local = N'true'
	begin
		-- parameter check: @action
		if @action is NULL or (LOWER(@action) not in (N'enable', N'disable'))
		begin
			raiserror (22810, 16, -1)
			return (1)
		end
		select @action = LOWER(@action)

		if @action = N'enable'
		begin

			if (@options & @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION) = @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION
			begin
				raiserror(22828, 16, -1, @publication, N'enabled')
				return (1) --already enabled
			end

			-- parameter check: @conflict_retention
			if (@conflict_retention < 0)
			begin
				raiserror(20050, 16, -1, 0)
				return (1)
			end

			-- parameter check: @continue_onconflict
			if LOWER(@continue_onconflict) not in (N'true', N'false')
			begin
				raiserror (14148, 16, -1, N'@continue_onconflict')
				return (1)
			end

			-- parameter check: @originator_id
			if @originator_id is not NULL and (@originator_id = 0 or @originator_id = 0x80000000)
			begin
				-- Originator ID provided is invalid: 0 or 0x80000000.
				select @strval = cast(@originator_id as nvarchar)
	              	raiserror(22806, 16, -1, @strval)
		              return (1)
			end 

			begin tran 
			save tran tr_sp_configure_p2pcd

			declare @numids int
			select @numids = count(*) from dbo.MSpeer_originatorid_history with (holdlock, tablock, xlock) -- X lock the whole table
			if @@error <> 0
				goto UNDO

        		--check/generate peer ID
			if @originator_id is null
			begin
				exec sp_MScheckgenerate_originatorid @publication = @publication, @old_originator_id = 0, @new_originator_id = @originator_id output
				if @@error <> 0
					goto UNDO
			end
			else
			begin
				declare @tmpid int
				exec sp_MScheckgenerate_originatorid @publication = @publication, @old_originator_id = @originator_id, @new_originator_id = @tmpid output
				if @@error <> 0
					goto UNDO
				
				if @tmpid = 0
				begin
					-- Originator ID provided is invalid: xxx.
					select @strval = cast(@originator_id as nvarchar)
					raiserror(22806, 16, -1, @strval)
					goto UNDO
				end
			end

			if LOWER(@continue_onconflict) = N'false'
				select @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT = 0x0

			--update options and originator_id
			update syspublications
			set	options = options | @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION | @OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT,
				originator_id = @originator_id,
				conflict_retention = @conflict_retention
			where pubid = @pubid
			
			select @enabling = 1
			
		end --@action: enable
		else
		begin
			if (@options & @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION) = 0
			begin
				raiserror(22828, 16, -1, @publication, N'disabled')
				return (1) --already disabled
			end

			begin tran 
			save tran tr_sp_configure_p2pcd

			--update options and originator_id
			update syspublications
			set	options = options & ~(@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION) & ~(@OPT_ENABLED_FOR_P2P_CONTINUE_ONCONFLICT),
				originator_id = NULL,
				conflict_retention = NULL
			where pubid = @pubid
			
			select @originator_id = 0

			select @enabling = 0

			delete from dbo.MSpeer_originatorid_history
			where originator_publication = @publication
			
		end -- @action: disable

		--ensure there are articles in the publication
		select @artid = MIN(artid)
		from sysarticles 
		where pubid = @pubid

		if (@artid is not NULL)
		begin
			--generate the script of processing hidden column, table persistent property and conflict table for all articles
			--for this peer, processing (add/remove, create/drop, set/reset) hidden column, table persistent property and conflict table for all articles
			exec @retcode = sp_MSscriptpeerconflictdetection_tableaug @pubid = @pubid, @publication = @publication, 
							@enabling = 	@enabling, @originator_id = @originator_id, @cmdtxt = @peercmdtxt output, @execscript = 1
			if @@error <> 0 or @retcode <> 0
			begin
				raiserror(21542, 16, 1, @@error, 'sp_configure_peerconflictdetection')
				goto UNDO
			end

			if @peercmdtxt is not NULL
			begin
				exec @retcode = sys.sp_replflush
				if @@error <> 0 or @retcode <> 0
				begin
					goto UNDO
				end

				-- post to log, which will be applied to the immediate subscribers
				exec @retcode = sys.sp_replpostcmd 0/*not partial*/, @pubid, @artid, 1/*@sql_cmd_type = SQL_CMD*/, @peercmdtxt
				if @retcode <> 0 or @@error <> 0
					goto UNDO

				--generate the script of custom procs for all articles
				select @peercmdtxt = N''
				exec @retcode = sp_MSscriptpeerconflictdetection_customprocs @publication = @publication, @cmdtxt = @peercmdtxt output
				if @@error <> 0 or @retcode <> 0
					goto UNDO

				-- post to log, which will be applied to the immediate subscribers, SQL_NOSYNCSETUPSCRIPT allows comments and "go" in the script
				exec @retcode = sys.sp_replpostcmd 0/*not partial*/, @pubid, @artid, 104/*@sql_cmd_type = SQL_NOSYNCSETUPSCRIPT*/, @peercmdtxt 
				if @retcode <> 0 or @@error <> 0
					goto UNDO
			end
			

		end --@artid is not NULL


		-- by sp_MSpeertopeerfwdingexec: executes and posts sp_MSchange_originatorid, which inserts the new ID 
		-- 							into MSpeer_lsns and MSpeer_originatorid_history
		exec @retcode = sys.sp_MSgetdbversion @current_version = @current_db_version output
		if @@error <> 0 or @retcode <> 0
			goto UNDO
		
		-- execute and post 'sp_MSchange_originatorid' by sp_MSpeertopeerfwdingexec
		select @peercmdtxt =	N'if (@@microsoftversion >= 0x0A000000) ' +
							N'begin' +
							N'	exec sys.sp_MSchange_originatorid @originator_node = N' + quotename(publishingservername(), N'''') + 
														N',@originator_db = N' + quotename(DB_NAME(), N'''') + 
														N',@originator_publication= N' + quotename(@publication, N'''') +
														N',@originator_publication_id = ' + cast(@pubid as nvarchar) + 
														N',@originator_db_version = '  + cast(@current_db_version as nvarchar) + 
														N',@originator_id = ' + cast(@originator_id as nvarchar) +
														N',@originator_version = ' + cast(@@microsoftversion as nvarchar) +
							N' end'
									
		--execute locally first then posted to log
		exec @retcode = sys.sp_MSpeertopeerfwdingexec @command = @peercmdtxt, @publication = @publication
		if @@error <> 0 or @retcode <> 0
			goto UNDO
				
		commit tran
		return (0)
		
	end --@local is true
	else --@local is false
	begin 
		-- parameter check: @action
		if @action is NULL or (LOWER(@action) not in (N'enable', N'disable', N'continue_enable', N'continue_disable'))
		begin
			raiserror (22810, 16, -1)
			return (1)
		end
		select @action = LOWER(@action)

		if @action = N'enable' or @action = N'continue_enable'
		begin
			-- parameter check: @conflict_retention
			if (@conflict_retention < 0)
			begin
				raiserror(20050, 16, -1, 0)
				return (1)
			end

			-- parameter check: @continue_onconflict
			if LOWER(@continue_onconflict) not in (N'true', N'false')
			begin
				raiserror (14148, 16, -1, N'@continue_onconflict')
				return (1)
			end
		end
		
		-- parameter check: @timeout
		if @timeout <= 0
		begin
			raiserror (22811, 16, -1)
			return (1)
		end 

		return (0)
	end --@local is false
	

UNDO:
	rollback tran tr_sp_configure_p2pcd
	commit tran
	return (1)
	
end
GO
GRANT EXECUTE ON [sys].[sp_configure_peerconflictdetection] TO [public] AS [dbo]
GO
