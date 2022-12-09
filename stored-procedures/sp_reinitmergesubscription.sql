SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_reinitmergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_reinitmergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_reinitmergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@upload_first [nvarchar](5)
WITH EXECUTE AS CALLER
AS
declare @pubid					uniqueidentifier
	declare @subid					uniqueidentifier
	declare @subscription_type		int
	declare @reinit_bit				int
	declare @publisher				sysname
	declare @publisher_db			sysname
	declare @distribdb				sysname
	declare @distributor			sysname
	declare @distproc				nvarchar(300)
	declare @retcode				int
	declare @uploadbit				bit
	declare @pubname				sysname
	declare @subdb					sysname 
	declare @subname				sysname
	declare @subscription_qualified bit
	declare @subscriber_server      sysname
	
	/* 
	** Security Check.
	** We use login_name stored in syssubscriptions to manage security 
	*/
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	set nocount on
	/*
	** Replace 'all' with '%'
	*/
	set @subscription_qualified = 0

	/* make sure current database is enabled for merge replication */
	exec @retcode=sys.sp_MSCheckmergereplication
	if @@ERROR<>0 or @retcode<>0
		return (1)

	if LOWER(@publication) = 'all'
		SELECT @publication = '%'

	if LOWER(@subscriber) = 'all'
		SELECT @subscriber = '%'

	if LOWER(@subscriber_db) = 'all'
		SELECT @subscriber_db = '%'

	select @publisher = publishingservername()
	select @publisher_db=db_name()
	
	/*
	** At publisher side, publication name is unique
	*/
	IF NOT EXISTS (SELECT * FROM dbo.sysmergepublications 
		WHERE name LIKE @publication)
		BEGIN
		IF @publication = '%'
				RAISERROR (14008, 11, -1)
		ELSE
				RAISERROR (20026, 11, -1, @publication)
		RETURN (1)
		END

	/* if snapshot has not been ran yet, there is no point doing reinitialization */
	if not exists (select * from dbo.sysmergepublications where name like @publication and snapshot_ready>0)
		return (0)
		
	if LOWER(@upload_first collate SQL_Latin1_General_CP1_CS_AS) = 'true'
		select @uploadbit  = 1
	else
		select @uploadbit  = 0

    /* upload_first is not supported for publications with compat level of 30 or lower. */
    if @uploadbit = 1 and exists (select * from dbo.sysmergepublications where name like @publication and 
        sys.fn_MSmerge_islocalpubid(pubid) = 1 and
        backward_comp_level < = 30)
    begin
		RAISERROR (20730, 11, -1)
		RETURN (1)    
    end

	EXECUTE @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT, @distribdb	  = @distribdb OUTPUT
		IF @@ERROR <> 0 or @retcode <> 0
				return (1)

	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSrefresh_anonymous '

	BEGIN TRAN
	SAVE TRAN reinitsubscription

	if @subscriber = '%' and @subscriber_db = '%'
	begin
		exec @retcode = @distproc @publication, @publisher, @publisher_db 
		if @@ERROR<>0 or @retcode<>0
				return (1)
				
		declare reinit_all CURSOR LOCAL FAST_FORWARD FOR 
			select name from dbo.sysmergepublications where LOWER(publisher)=LOWER(publishingservername()) and 
				publisher_db=db_name() and snapshot_ready>0 and name like @publication
		For READ only
		open reinit_all
		fetch reinit_all into @pubname
		while (@@fetch_status<>-1)
		begin
			exec @retcode = sys.sp_MSreinitmergepublication @pubname, @uploadbit
			if @@ERROR<>0 or @retcode<>0
			begin
				close reinit_all
				deallocate reinit_all
				return (1)
			end
			
			fetch next from reinit_all into @pubname
		end
		close reinit_all
		deallocate reinit_all
	end

	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSmarkreinit '

	
	
	Declare SYN_CUR CURSOR LOCAL FAST_FORWARD FOR 
		select subs.subid, subs.subscription_type, pubs.publisher, pubs.publisher_db, pubs.name, 
				subs.subscriber_server, subs.db_name
			from dbo.sysmergepublications pubs, dbo.sysmergesubscriptions subs
				where pubs.name LIKE  @publication 
					 and UPPER(pubs.publisher)=UPPER(publishingservername()) 
					 and pubs.publisher_db=db_name()
					AND pubs.pubid=subs.pubid
					AND subs.pubid<>subs.subid
					AND subs.status <>0 --for unsynced subscription, there is no need to reinit.
					AND ((@subscriber_db = N'%') or (subs.db_name = @subscriber_db))
					AND ((@subscriber = N'%') or (UPPER(subs.subscriber_server) = UPPER(@subscriber) collate database_default))
	FOR READ ONLY
	open SYN_CUR
	fetch SYN_CUR into @subid, @subscription_type, @publisher, @publisher_db, @pubname, @subscriber_server, @subdb
	while (@@fetch_status<>-1)
	BEGIN  
	-- Security check 
		if is_member('db_owner')<>1 and
		   not exists (select * from dbo.MSmerge_replinfo where suser_sname(suser_sid()) = login_name and repid = @subid)
		begin
			fetch next from SYN_CUR into @subid, @subscription_type, @publisher, @publisher_db, @pubname, @subscriber_server, @subdb		  
			continue
		end
	
		if @subscription_type = 0 
			 update dbo.sysmergesubscriptions set schemaversion=0, recgen = NULL, recguid=NULL, sentgen=NULL, sentguid = NULL
				  where subid=@subid and schemaversion is NOT NULL
		else
			 update dbo.sysmergesubscriptions set schemaversion= -1, recgen = NULL, recguid=NULL, sentgen=NULL, sentguid = NULL
				  where subid=@subid and schemaversion is NOT NULL
		
		if @@rowcount <> 0
		begin
			if @uploadbit = 1
				update dbo.sysmergesubscriptions set status = 5 where subid=@subid
			else
			begin
				-- if they have previously requested reinit with upload first=true, status
				-- has been changed to 5. We have lost the info about the status before the 
				-- previous reinit. Use last_sync_status to determine whether the new status
				-- should be 0 or 1.
				update dbo.sysmergesubscriptions set status = 
					case when last_sync_status is null then 0 else 1 end
				where subid=@subid
				and status = 5
			end
			if @@ERROR<>0
				goto Failure
		end
			
		-- make sure we don't falsely use transitive recgen optimization
		update dbo.sysmergesubscriptions
			set replicastate= newid() where subid = @subid

		-- 0 for push and -1 for pull
		exec @distproc @publisher, @publisher_db, @pubname, @subscriber_server, @subdb, 1
		if @@ERROR<>0
		BEGIN
			goto Failure
		END			

		set @subscription_qualified = 1
		fetch next from SYN_CUR into @subid, @subscription_type, @publisher, 
			@publisher_db, @pubname, @subscriber_server, @subdb		  
	END
	close SYN_CUR
	deallocate SYN_CUR
	commit TRAN

	/* If subscription has not been reinited possibly because it is invalid or anonymous, return a warning */
	if @subscription_qualified = 0 and @subscriber <> '%' and @subscriber_db <> '%'
	begin
		RAISERROR(21719, 10, -1, @subscriber, @subscriber_db)
	end
		
	return (0)
Failure:
	close SYN_CUR
	deallocate SYN_CUR
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRANSACTION reinitsubscription
		COMMIT TRANSACTION
	end
	return (1)

GO
GRANT EXECUTE ON [sys].[sp_reinitmergesubscription] TO [public] AS [dbo]
GO
