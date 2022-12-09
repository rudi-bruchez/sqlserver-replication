SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_publication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@alt_snapshot_folder [sysname],
	@cleanup_orphans [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
				,@publication_id int
				,@retcode int
				,@article sysname
				,@article_id int
				,@subscriber sysname
				,@subscriber_db sysname
				,@thirdparty_flag bit
				,@working_dir nvarchar(255)
				,@pub_dir nvarchar(255)
				,@pathSeparator nvarchar(2)
	
	select @pathSeparator = CAST(SERVERPROPERTY('pathseparator') as nvarchar(2))

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
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSdrop_publication', 'distribution')
		return (1)
	end

	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Make sure publication exists
	select @publication_id = publication_id, @thirdparty_flag = thirdparty_flag 
		from dbo.MSpublications where publication = @publication and
		publisher_id = @publisher_id and publisher_db = @publisher_db
	if @publication_id is NULL
	begin
		-- We don't know whether or not it is a third party or not so we can not 
		-- return error.
		-- raiserror(20026, 16, -1, @publication)
		-- return (1)
		return (0)
	end

    if (@cleanup_orphans = 0)
    begin
        -- Make sure that there are no subscriptions on the publication.
        if exists (select * from dbo.MSsubscriptions s, dbo.MSpublications p where 
            p.publisher_id = @publisher_id and
            p.publisher_db = @publisher_db and
            p.publication = @publication and
            s.publisher_id = @publisher_id and
            s.publisher_db = @publisher_db and
            s.publication_id = p.publication_id and
            s.subscriber_id >= 0)               -- ignore virtual subscriptions
        begin
            raiserror(14005, 16, -1)
            return(1)
        end
        -- No real subscriptions exist, so delete any virtual subscriptions.
        exec sys.sp_MSdrop_subscription
	        @publisher = @publisher,
	        @publisher_db = @publisher_db,
	        @publication = @publication,
	        @subscriber = null
    end
    else
    begin
        --
        -- cleanup existing subscriptions since we are dropping this publication
        --
        declare #hcsubart cursor LOCAL FAST_FORWARD FOR 
            select s.article_id, upper(ss.srvname collate database_default), s.subscriber_db
            from dbo.MSsubscriptions as s 
                join dbo.MSpublications as p
                    on s.publisher_id = p.publisher_id
                        and s.publisher_db = p.publisher_db
                        and s.publication_id = p.publication_id
                        and s.subscriber_id >= 0 -- ignore virtual subscriptions
                join MSreplservers as ss
                    on s.subscriber_id = ss.srvid
            where p.publisher_id = @publisher_id 
                and p.publisher_db = @publisher_db 
                and p.publication = @publication 

		open #hcsubart
		fetch #hcsubart into @article_id, @subscriber, @subscriber_db
		while (@@fetch_status != -1)
		begin
			exec sys.sp_MSdrop_subscription
							@publisher = @publisher,
							@publisher_db = @publisher_db,
							@subscriber = @subscriber,
							@article_id = @article_id,
							@subscriber_db = @subscriber_db,
							@publication = @publication
			fetch #hcsubart into @article_id, @subscriber, @subscriber_db
		end
		close #hcsubart
		deallocate #hcsubart
		-- delete any virtual subscriptions.
		exec sys.sp_MSdrop_subscription
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@publication = @publication,
	  			@subscriber = null

	end

	SELECT @working_dir = working_directory FROM msdb..MSdistpublishers
		where UPPER(name) = UPPER(@publisher)

	IF @working_dir IS NOT NULL
	BEGIN
		-- Remove the pub dir under UNC and FTP if it exists
		-- Note: sp_MSreplremoveuncdir will convert unc path to local path.
		-- This is required. Otherwise we will see 'Access denied' error.
		SELECT @pub_dir = CONCAT(@working_dir, @pathSeparator, 'unc', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 1) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@working_dir, @pathSeparator, 'ftp', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 1) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@working_dir, @pathSeparator, 'unc', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 0) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@working_dir, @pathSeparator, 'ftp', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 0) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

	END

	IF @alt_snapshot_folder IS NOT NULL AND RTRIM(@alt_snapshot_folder) <> N''
	BEGIN

		-- Make sure that alt_snapshot_folder is \ terminated
		IF SUBSTRING(@alt_snapshot_folder,len(@alt_snapshot_folder),1) <> @pathSeparator
		BEGIN
			SELECT @alt_snapshot_folder = @alt_snapshot_folder + @pathSeparator
		END

		-- Remove the pub dir under UNC and FTP if it exists
		-- Note: sp_MSreplremoveuncdir will convert unc path to local path.
		-- This is required. Otherwise we will see 'Access denied' error.
		SELECT @pub_dir = CONCAT(@alt_snapshot_folder, 'unc', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 1) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@alt_snapshot_folder, 'ftp', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 1) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@alt_snapshot_folder, 'unc', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 0) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

		SELECT @pub_dir = CONCAT(@alt_snapshot_folder, 'ftp', @pathSeparator,
					fn_replcomposepublicationsnapshotfolder(@publisher,@publisher_db,@publication, 0) collate database_default)
		exec @retcode = sys.sp_MSreplremoveuncdir @pub_dir, 1
		if @retcode <> 0 or @@error <> 0
			return(1)

	END
	
	begin tran
	save tran MSdrop_publication

	-- Delete all articles if a third party publication
	if @thirdparty_flag = 1 
	begin
		-- Delete all articles in the publication
		declare hCarticles CURSOR LOCAL FAST_FORWARD FOR select article from MSarticles where 
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication_id = 
				(select publication_id from dbo.MSpublications where 
					publisher_id = @publisher_id and
					publisher_db = @publisher_db and
					publication = @publication)
		open hCarticles
		fetch hCarticles into @article
		while (@@fetch_status <> -1)
		begin
			exec @retcode = sys.sp_MSdrop_article @publisher, @publisher_db, @publication, @article
			if @retcode != 0 or @@error != 0
			begin
				close hCarticles
				deallocate hCarticles
				goto UNDO
			end
				
			fetch hCarticles into @article
		end
		close hCarticles
		deallocate hCarticles
	end
	--
	-- remove threshold entries for this publication
	--
	delete dbo.MSpublicationthresholds 
		where publication_id = @publication_id
	if @@error <> 0
		goto UNDO
	--
	-- remove entry from dbo.MSpublications
	--
	delete from dbo.MSpublications where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @@error <> 0
	begin
		raiserror (14006, 16, -1)
		goto UNDO
	end

	-- Drop snapshot agent
	exec @retcode = sys.sp_MSdrop_snapshot_agent
			@publisher = @publisher,
			@publisher_db = @publisher_db,
			@publication = @publication
	if @@ERROR<> 0 or @retcode <> 0
		goto UNDO

	-- delete cache for this agent
	delete MScached_peer_lsns 
			where agent_id in (select id
								from MSdistribution_agents 
								where publisher_id = @publisher_id
									and publisher_db = @publisher_db 
									and publication = @publication)
	if @@ERROR<> 0
		goto UNDO
	
	-- Delete anonymous agents
	delete MSdistribution_agents where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @@ERROR<> 0 or @retcode <> 0
		goto UNDO

delete from dbo.MSmerge_subscriptions
where       publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication_id = @publication_id


	delete dbo.MSmerge_articlehistory
		from dbo.MSmerge_articlehistory arthist join dbo.MSmerge_sessions sess
		on arthist.session_id=sess.session_id
		where sess.agent_id in 
		(select id from dbo.MSmerge_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication)
	IF @@ERROR <> 0 
		GOTO UNDO
		
	delete dbo.MSmerge_history
		from dbo.MSmerge_history hist join dbo.MSmerge_sessions sess
		on hist.session_id=sess.session_id
		where sess.agent_id in 
		(select id from dbo.MSmerge_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication)
	IF @@ERROR <> 0 
		GOTO UNDO
		
	delete dbo.MSrepl_errors
		from dbo.MSrepl_errors errs join dbo.MSmerge_sessions sess
		on errs.session_id=sess.session_id
		where sess.agent_id in 
		(select id from dbo.MSmerge_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication)
	IF @@ERROR <> 0 
		GOTO UNDO
		
	-- delete sessions entries 
	delete dbo.MSmerge_sessions where agent_id in 
		(select id from dbo.MSmerge_agents where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication)
			
	delete dbo.MSmerge_agents where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @@ERROR<> 0 or @retcode <> 0
		goto UNDO

	-- Cleanup publication access list table
	delete dbo.MSpublication_access where
		publication_id = @publication_id
	if @@ERROR<> 0 or @retcode <> 0
		goto UNDO

    -- cleanup identity range allocation history information
    delete dbo.MSmerge_identity_range_allocations 
        where publisher_id = @publisher_id and
              publisher_db = @publisher_db and
              publication = @publication
    if @@ERROR<> 0 or @retcode <> 0
        goto UNDO
              
    -- Remove publisher_id, publisher_db pair if no other publication is using it.
    if not exists (select * from msdb.dbo.MSdistpublishers d, MSreplservers s
	where s.srvid = @publisher_id
	and upper(s.srvname) = upper(d.name) collate database_default
	and upper(d.publisher_type) LIKE 'ORACLE%' )
	and
	   not exists (select * from dbo.MSpublications where publisher_id = @publisher_id and
		publisher_db = @publisher_db)
	begin
		declare @publisher_database_id int

		select @publisher_database_id = id from MSpublisher_databases where 
			publisher_id = @publisher_id and 
			publisher_db = @publisher_db

		delete from MSrepl_backup_lsns where 
			publisher_database_id = @publisher_database_id

		delete from MSpublisher_databases where 
			publisher_id = @publisher_id and publisher_db = @publisher_db
		if @@error <> 0
			goto UNDO

		-- Cleaning up MSrepl_originators
		delete MSrepl_originators where
			publisher_database_id = @publisher_database_id
		if @@error <> 0
			goto UNDO
	end
	--
	-- commit all the work
	--
	commit tran
	--
	-- all done
	--
	return 0

UNDO:
	if @@trancount > 0
	begin
		rollback tran MSdrop_publication
		commit tran
	end
	return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_publication] TO [public] AS [dbo]
GO
