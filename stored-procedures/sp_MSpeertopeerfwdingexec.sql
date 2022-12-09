SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeertopeerfwdingexec]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeertopeerfwdingexec] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeertopeerfwdingexec]
	@command [nvarchar](max),
	@publication [sysname],
	@execute [bit],
	@change_results_originator [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @OPT_ENABLED_FOR_P2P int
	
	declare @retcode 	int,
			@cmd_type 	int,
			@pubid		int,
			@artid		int
			
	select @OPT_ENABLED_FOR_P2P = 0x1
		
	-- security check for subscriber
	-- Though the work below is related to a publisher, we use 
	-- a check for the subscriber because this is normally executed
	-- by the distribution agent at a subscriber (republisher).
	-- this should only be used by peer to peer subscribers.
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or @retcode <> 0 
    begin
        return 1
    end
	
	begin transaction tran_sp_MSpeertopeerfwdingexec
	save transaction tran_sp_MSpeertopeerfwdingexec

	-- only exec the command if we have been requested to do so
	if @execute = 1
	begin
		exec(@command)
		if @@error <> 0 
		begin
			goto FAILURE
		end
	end
	
	-- if this is not a republisher then we can just commit and exit
	if sys.fn_MSrepl_istranpublished(db_name(),0) = 0
    begin
		goto COMMIT_TRAN
    end

	/*
	 * Here we begin to perform the fwding...
	 */
			
	-- we will post this for the peer publication that is in 
	-- this database and matches the originator publication
	select @pubid = sp.pubid,
  			@artid = min(sa.artid)
    	from syspublications sp
    		join sysextendedarticlesview sa
    			on sp.pubid = sa.pubid
    	where (sp.options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P
    		and sp.name = @publication
		group by sp.pubid

	-- if we do not find a publication or article then we just do a no-op
	if @pubid is NULL
		or @artid is NULL
	begin
		goto COMMIT_TRAN
	end

	-- Here we will set the command type and command based on 
	-- wether or not we want to have the commands results proxied
	if @change_results_originator = 1
	begin
		-- in this case post as proxied cmd
		select @cmd_type = 42	-- REPL_PEERTOPEERPROXIEDCMD
	end
	else
	begin
		-- in this case post as forwarding cmd
		select @cmd_type = 43	-- REPL_PEERTOPEERFWDINGCMD
	end
	
	exec @retcode = sys.sp_replpostcmd 0, @pubid, @artid, @cmd_type, @command
	if @@error <> 0 or @retcode <> 0 
	begin
		goto FAILURE
	end
   
COMMIT_TRAN:
	commit transaction tran_sp_MSpeertopeerfwdingexec
	return 0

FAILURE:
	-- An error occurred executing a Peer-To-Peer forwarding command.
	raiserror(20806, 16, -1)
	
	rollback transaction tran_sp_MSpeertopeerfwdingexec
	commit transaction tran_sp_MSpeertopeerfwdingexec

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeertopeerfwdingexec] TO [public] AS [dbo]
GO
