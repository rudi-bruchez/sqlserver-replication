SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetpeertopeercommands]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetpeertopeercommands] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetpeertopeercommands]
	@publication [sysname],
	@article [sysname],
	@snapshot_lsn [varbinary](16),
	@script_txt [nvarchar](max) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 					int,
			@publisher 					sysname,
			@publisher_db 				sysname,
			@publisher_db_version		int,
			@is_p2p 					bit,
			@pubid						int,
			@artid						int,
			@current_article		    sysname,
			@dest_table					sysname,
			@dest_owner					sysname,
			@min_artid					int,
			@command					nvarchar(4000),
			@originator					sysname,
			@originator_db				sysname,
			@originator_publication		sysname,
			@originator_publication_id	int,
			@originator_db_version		int,
			@originator_lsn				varbinary(16),
			@originator_lsn_str			varchar(2000),
			@originator_version		int,
			@originator_id				int
	
	declare @OPT_ENABLED_FOR_P2P int

	select @OPT_ENABLED_FOR_P2P = 0x1
	
	declare @art_commands table (artid int NOT NULL, commands nvarchar(4000) collate database_default null, id int identity NOT NULL)
	
    -- Security Check
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
	end
	
   	-- set the publishd and database name
    select @publisher 		= publishingservername(),
    		@publisher_db 	= db_name()
			
	-- Parameter Check:  @publication
    if @publication IS NULL
    begin
        raiserror(14043, 16, -1, '@publication', 'sp_MSgetpeertopeercommands')
        return 1
	end
	
	-- validate @publication
    exec @retcode = sys.sp_validname @publication
    if @@error <> 0 OR @retcode <> 0
    	return 1
    	
    -- get publication metadata
    select @pubid = pubid,
    		@is_p2p = (options & @OPT_ENABLED_FOR_P2P)
    	from syspublications 
    	where name = @publication
    if @pubid is null
    begin
        raiserror (20026, 11, -1, @publication)
        return 1
    end

	-- exit with no error if we are not a PeerToPeer publication
    if @is_p2p = 0
	begin
    	select @script_txt = NULL
		return 0
	end

	-- retrieve the database version 
	exec sys.sp_MSgetdbversion @current_version = @publisher_db_version output
	if @@error <> 0 OR @retcode <> 0
    	return 1
    
	/*
	 * This section creates commands to be posted to the distribution database
	 * that will insert all necessary MSsubscription_articles entries at the
	 * subscriber database. These entries are only used to validate topology,
	 * publication and subscription configurations. The commands should only
	 * be added for the non-database-restore case. Also, keep in mind that 
	 * these commands will not be forwarded throughout the topology...
	 * Remember that we must include extended articles as well (SP, FN, V)
	 */
	declare publication_art_cursor cursor local fast_forward for
		select sa.artid,
				sa.name,
				sa.dest_table,
				isnull(sa.dest_owner, N'dbo')
			from sysextendedarticlesview sa
			where sa.pubid = @pubid
              and (@article = N'all' 
              		or name = @article)
	for read only
	
	open publication_art_cursor

    fetch publication_art_cursor into @artid, @current_article, @dest_table, @dest_owner
								
    while (@@fetch_status <> -1)
    begin
    	select @command = N'if (@@microsoftversion >= 0x09000000)' + 
					  		N' begin' +
    							N' exec sys.sp_MSaddsubscriptionarticles @publisher=N' + quotename(@publisher, N'''')  + 
																		N',@publisher_db=N' + quotename(@publisher_db, N'''')  + 
																		N',@publication=N' + quotename(@publication, N'''')  + 
																		N',@artid=' + cast(@artid as nvarchar)  +
																		N',@article=N' + quotename(@current_article, N'''')  +
																		N',@dest_table=N' + quotename(@dest_table, N'''')  +
																		N',@dest_owner=N' + quotename(@dest_owner, N'''')  +
							N' end'

		-- if this is NOT the first article for this subscription 
		-- (in other words this is an incremental add article) then
		-- we will validate the individual article immediately after
		-- adding it's sub_article meta-data. if this is not the case
		-- (and this is the first article for the sub) then we will
		-- perform one validation that will verify all articles instead
		if @article != N'all'
		begin
			select @command = @command + N' ' +
							N'if (@@microsoftversion >= 0x09000000)' + 
					  		N' begin' +
								N' exec sys.sp_MSdetectinvalidpeersubscription @publisher=N' + quotename(@publisher, N'''')  + 
																			N',@publisher_db=N' + quotename(@publisher_db, N'''')  + 
																			N',@publication=N' + quotename(@publication, N'''')  + 
																			N',@article=N' + quotename(@current_article, N'''')  +
																			N',@dest_table=N' + quotename(@dest_table, N'''')  +
																			N',@dest_owner=N' + quotename(@dest_owner, N'''')  +
																			N',@type=''ADD''' +
					  		N' end'
		end
		
		if @command is not null
		begin
			if @script_txt is NULL
			begin
				insert into @art_commands values (@artid, @command)
			end
			else
			begin
				select @script_txt = @script_txt + @command + N' '
			end
		end

		fetch publication_art_cursor into @artid, @current_article, @dest_table, @dest_owner
    end

    close publication_art_cursor
    deallocate publication_art_cursor

	-- if this is the subscriptions first article then 
	-- we will perform the extensive article checks that
	-- validates the entire publication and it's articles.
	if @article = N'all'
	begin
	    -- now insert a command to verify that after the commands above are applied there
	    -- are no invalid publication/subscription combinations in the subscriber db
	    select @command = N'if (@@microsoftversion >= 0x09000000)' + 
					  		N' begin' +
					  			N' exec sys.sp_MSdetectinvalidpeerconfiguration @publisher=N' + quotename(@publisher, N'''')  + 
																			N',@publisher_db=N' + quotename(@publisher_db, N'''')  + 
																			N',@publication=N' + quotename(@publication, N'''')  + 
							N' end'

		if @command is not null
		begin
			if @script_txt is NULL
			begin
				insert into @art_commands values (@artid, @command)
			end
			else
			begin
				select @script_txt = @script_txt + @command + N' '
			end
		end
	end
	
	/*
	 * This section creates commands to be posted to the distribution database
	 * that will insert all necessary init records into the LSN table.
	 */

	-- retrieve the min artid so that we can use it when posting PeerToPeer 
	-- commands that do not originate from this server/publisherdb/publication
	select @min_artid = min(artid) from sysextendedarticlesview where pubid = @pubid and (@article = N'all' or name = @article)

	-- collect peer to peer lsns for a specific publication meta-data on this 
	-- machine. note that here we use @publication instead of @pubid because the 
	-- @pubid could possibly have a different value at each originator database.
    declare peer_art_cursor cursor local fast_forward for
		select mspl.originator,
				mspl.originator_db,
				mspl.originator_publication,
				mspl.originator_publication_id,
				mspl.originator_db_version,
				mspl.originator_lsn,
				mspl.originator_version,
				mspl.originator_id
			from MSpeer_lsns mspl
			where mspl.originator_publication = @publication
	for read only
	
    open peer_art_cursor

    fetch peer_art_cursor into @originator, @originator_db, @originator_publication,
								@originator_publication_id,	@originator_db_version,	@originator_lsn, @originator_version, @originator_id

    while (@@fetch_status <> -1)
    begin
    	select @originator_lsn_str = sys.fn_varbintohexstr (@originator_lsn)

    		if @originator_id is NULL
    			select @originator_id = 0
    	
		select @command = N'if (@@microsoftversion >= 0x0A000000)' + 
						  	N' begin' +
						  		N' exec sys.sp_MSaddpeerlsn @originator=N' + quotename(@originator, N'''') + 
														N',@originator_db=N' + quotename(@originator_db, N'''') + 
														N',@originator_publication=N' + quotename(@originator_publication, N'''') +
														N',@originator_publication_id=' + cast(@originator_publication_id as nvarchar) + 
														N',@originator_db_version='  + cast(@originator_db_version as nvarchar) + 
														N',@originator_lsn=0x0' +
														N',@originator_version=' + cast(@originator_version as nvarchar) +
														N',@originator_id=' + cast(@originator_id as nvarchar) +
							N' end' +
						  N' else if (@@microsoftversion >= 0x09000000)' + 
						  	N' begin' +
						  		N' exec sys.sp_MSaddpeerlsn @originator=N' + quotename(@originator, N'''') + 
														N',@originator_db=N' + quotename(@originator_db, N'''') + 
														N',@originator_publication=N' + quotename(@originator_publication, N'''') +
														N',@originator_publication_id=' + cast(@originator_publication_id as nvarchar) + 
														N',@originator_db_version='  + cast(@originator_db_version as nvarchar) + 
														N',@originator_lsn=0x0' +
							N' end'
		
		select @command = N' if (@@microsoftversion >= 0x09000000)' + 
							  	N' begin' +
							  		N' exec sys.sp_MSpeertopeerfwdingexec @command=N''' + replace(@command, N'''', N'''''') + N'''' +
															N',@publication=N' + quotename(@originator_publication, N'''') +
							  	N' end'

		if @command is not null
		begin
			if @script_txt is NULL
			begin
				insert into @art_commands values (@min_artid, @command)
			end
			else
			begin
				select @script_txt = @script_txt + @command + N' '
			end
		end

		-- when adding the lsn for the publisher we want to update it 
    	-- to the current snapshot lsn. this is because the snapshot may 
    	-- contain bcp files with data that we will not want to reapply.
    	-- keep in mind that this should only be done for regular snapshot
    	-- and not the auto-nosync case (there are no bcp files for autonosync)
    	-- also do not forward this command since it is only meant to adjust
    	-- the lsn for the case where a bcp file was applied via snapshot.
    	if @script_txt is NULL
    		and UPPER(@originator) = UPPER(@publisher)
    		and @originator_db = @publisher_db
    		and @originator_publication_id = @pubid
    		and @originator_db_version = @publisher_db_version
    	begin
			select @originator_lsn_str = sys.fn_varbintohexstr (@snapshot_lsn)

			select @command = N'if (@@microsoftversion >= 0x09000000)' + 
						  	N' begin' +
						  		N' exec sys.sp_MSupdatepeerlsn @originator=N' + quotename(@originator, N'''') + 
														N',@originator_db=N' + quotename(@originator_db, N'''') +
														N',@originator_publication_id=' + cast(@originator_publication_id as nvarchar) + 
														N',@originator_db_version='  + cast(@originator_db_version as nvarchar) + 
														N',@originator_lsn='  + @originator_lsn_str +
							N' end'

			insert into @art_commands values (@min_artid, @command)
		end
		
	    fetch peer_art_cursor into @originator, @originator_db, @originator_publication,
								@originator_publication_id,	@originator_db_version,	@originator_lsn, @originator_version, @originator_id
    end

    close peer_art_cursor
    deallocate peer_art_cursor
	
	-- return all commands to the client
	if @script_txt is NULL
	begin
		select * 
		   	from @art_commands 
		   	order by id
	end
	
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetpeertopeercommands] TO [public] AS [dbo]
GO
