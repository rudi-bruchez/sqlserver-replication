SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreinit_hub]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreinit_hub] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreinit_hub]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@upload_first [bit]
WITH EXECUTE AS CALLER
AS
-- Lightweight subscribers never are republishers.
	if 1 = sys.fn_MSuselightweightreplication
				(@publisher, @publisher_db, @publication, null, null, null, null)
	begin
		return 0
	end

	declare @retcode			int
	declare @pubid				uniqueidentifier
	declare @hub_pubname		sysname
	declare @hub_publisher		sysname
	declare @hub_publisher_db	sysname
	declare @hub_pubid			uniqueidentifier
	declare @schematext			nvarchar(4000)
	declare @schemaversion		int
	declare @schemaguid			uniqueidentifier
	declare @schematype			int
	declare @compatlevel int

    -- Security Check.
	exec @retcode= sys.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
	
	select @pubid=pubid, @compatlevel = backward_comp_level from dbo.sysmergepublications 
		where name=@publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db
	BEGIN TRAN
	SAVE TRAN reinithub
	
	/* Find all publications that are being republished at the subscriber */
	declare reinit_hub CURSOR LOCAL FAST_FORWARD FOR select DISTINCT p.pubid, p.name, p.publisher, p.publisher_db FROM dbo.sysmergepublications p
		where UPPER(p.publisher)=UPPER(publishingservername()) and p.publisher_db=db_name()
			and exists (select * from dbo.sysmergearticles where (objid in 
					(select objid from dbo.sysmergearticles where pubid=@pubid)) and (objid in 
					(select objid from dbo.sysmergearticles where pubid=p.pubid))) and p.pubid<>@pubid
	FOR READ ONLY
	open reinit_hub
	fetch reinit_hub into @hub_pubid, @hub_pubname, @hub_publisher, @hub_publisher_db
	while (@@fetch_status<>-1)
	begin
		if @upload_first=1
		begin
			update dbo.sysmergesubscriptions set status=5 where pubid=@hub_pubid
			if @@ERROR<>0
				goto FAILURE
		end
		else
		begin
			-- if they have previously requested reinit with upload first=true, status
			-- has been changed to 5. We have lost the info about the status before the 
			-- previous reinit. Use last_sync_status to determine whether the new status
			-- should be 0 or 1.
			update dbo.sysmergesubscriptions set status = 
				case when last_sync_status is null then 0 else 1 end
			where pubid=@hub_pubid
			and status = 5
			
			if @@ERROR<>0
				goto FAILURE
		end
		select @schematext = 'exec dbo.sp_MSreinit_hub '+ QUOTENAME(@hub_publisher) + ', ' + QUOTENAME(@hub_publisher_db) + ', ' + QUOTENAME(@hub_pubname) + ', ' + convert(nvarchar, @upload_first)
		select @schemaversion = schemaversion from dbo.sysmergeschemachange
		if (@schemaversion is NULL)
			set @schemaversion = 1
		else
			select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange		
		set @schemaguid = newid()
		if @upload_first=0
			set @schematype = 12 /* reinit_all */
		else
			set @schematype = 14 /*reinitwithupload */
		exec @retcode=sys.sp_MSinsertschemachange @hub_pubid, null, @schemaversion, @schemaguid, @schematype, @schematext
		if @@ERROR<>0 or @retcode<>0
		begin
			select @retcode = 1
			GOTO FAILURE
		end
		if @compatlevel < 40
		begin
    		raiserror(21354, 10, -1, @hub_pubname)
    		exec @retcode=sys.sp_MSBumpupCompLevel @hub_pubid, 40 
    		if @@ERROR<>0 or @retcode<>0		
    			GOTO FAILURE
    	end

		update dbo.sysmergepublications set snapshot_ready=2 where pubid=@hub_pubid
		if @@ERROR<>0
			goto FAILURE
		fetch next from reinit_hub into @hub_pubid, @hub_pubname, @hub_publisher, @hub_publisher_db
	end
	close reinit_hub
	deallocate reinit_hub
	COMMIT TRAN
	return (0)
FAILURE:
	close reinit_hub
	deallocate reinit_hub
	raiserror('Error occurred when applying reinit-all command at subscribers', 16, -1)
	if @@TRANCOUNT >0 
	begin
		ROLLBACK TRANSACTION reinithub
		COMMIT TRAN
	end
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSreinit_hub] TO [public] AS [dbo]
GO
