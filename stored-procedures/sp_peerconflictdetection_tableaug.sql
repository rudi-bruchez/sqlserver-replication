SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_peerconflictdetection_tableaug]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_peerconflictdetection_tableaug] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_peerconflictdetection_tableaug]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@enabling [bit],
	@originator_id [int],
	@artlist [nvarchar](max)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	
	declare	@retcode int = 0,        
			@tabrepobjsexists bit, 
			@OPT_ENABLED_FOR_P2P int = 0x1,
			@OPT_ENABLED_FOR_P2P_CONFLICTDETECTION int = 0x8,
			@ispub bit, --used only when disabling
			@cursor_allocated bit = 0,
			@cursor_opened bit = 0,
			@schname sysname,
			@tabname sysname,
			@artname sysname,
			@schema_option bigint,
			@fulltablename nvarchar(540), --qualified with owner
			@tabobjid int,
			@conftabname nvarchar(540),
			@forcetabaug bit  --used only when disabling

	-- security check - should be dbo or sysadmin
	if (@originator_id = 0x80000000) --read-only subscriber
	begin
		exec @retcode = sp_MSreplcheck_subscribe
		if @@ERROR != 0 or @retcode != 0
			return (1)
	end
	else
	begin
		exec @retcode = sp_MSreplcheck_publish
		if @@ERROR != 0 or @retcode != 0
			return (1)
	end

	-- obtain article list
	declare @arttab table (schname sysname,  tabname sysname,  artname sysname,  schema_option bigint)
	declare @DocHandle int

	begin tran
	save tran tr_tableaug
	
	exec sp_xml_preparedocument @DocHandle OUTPUT, @artlist
	if @@error <> 0
		goto UNDO
	
	insert @arttab
		select  * 	
		from OPENXML (@DocHandle, N'/arts/art', 1)
		with (schname sysname,  tabname sysname,  artname sysname,  schema_option bigint)
	if @@error <> 0
		goto UNDO
	
	exec sp_xml_removedocument @DocHandle
	if @@error <> 0
		goto UNDO

	if exists (select * from sys.objects where name = N'MSreplication_objects')
		select @tabrepobjsexists = 1 
	else
		select @tabrepobjsexists = 0


	if @enabling = 1
	begin --read-only subscription table has its p2porid as 0x80000000
		if not exists (select * from sys.objects where name = N'syspublications') 
			select @originator_id = 0x80000000
		else if not exists (select * from syspublications 
					where name = @publication 
					and options & @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION = @OPT_ENABLED_FOR_P2P_CONFLICTDETECTION) 
			select @originator_id = 0x80000000
	end
	else
	begin
		if not exists (select * from sys.objects where name = N'syspublications') 
			select @ispub = 0 
		else if not exists (select * from syspublications 
				where name = @publication 
				and options & @OPT_ENABLED_FOR_P2P = @OPT_ENABLED_FOR_P2P)
			select @ispub  = 0
		else
			select @ispub  = 1
	end
	
	--process all articles
	declare #harticle cursor local fast_forward for
	select * from @arttab

	if (@@error != 0)
		goto UNDO

	select @cursor_allocated = 1

	open #harticle
	if (@@error != 0)
		goto UNDO

	select @cursor_opened = 1

	fetch #harticle into @schname, @tabname, @artname, @schema_option 
	while (@@fetch_status<>-1)
	begin
		select @fulltablename = QUOTENAME(@schname) + N'.' + QUOTENAME(@tabname)
		select @tabobjid = object_id(@fulltablename)
		if(@tabobjid is not NULL and exists (select * from sys.objects where object_id = @tabobjid and type = N'U'))
		begin
			select @conftabname =sys.fn_peerconflicttablename(@fulltablename)
			
			if @enabling = 1 --create conflict table and insert object name into MSreplication_objects in case of read-only subscriptions
			begin
				if @originator_id <> 0x80000000 --do not create conflict table on a read-only subscriber for now
				begin
					exec @retcode = sp_MSmakepeerconflicttable @fulltablename , @schema_option 
					if @@error != 0 or @retcode = 1
						goto UNDO

					--leave the code to insert into MSreplication_objects here
					if @originator_id = 0x80000000 and  @tabrepobjsexists  = 1
					begin
						if not exists (select * from dbo.MSreplication_objects where object_name =@conftabname
																	and publisher = @publisher
																	and publisher_db = @publisher_db 
																	and publication = @publication
																	and article = @artname
																	and object_type = N'U')
					  		insert dbo.MSreplication_objects (publisher, publisher_db, publication, object_name, object_type, article)
							values(@publisher, @publisher_db, @publication, @conftabname, N'U', @artname)
					end	
				end

							
				EXEC %%Object(MultiName = @fulltablename).LockMatchID(ID = @tabobjid, Exclusive = 1, BindInternal = 0)
				--enabling: for read-only subscription, @replpeerid is 0x80000000; for peer,  @replpeerid is @originator_id
				--this will internally add hidden column
				exec %%Relation(ID = @tabobjid).SetReplPeerId(Value = @originator_id)
				if @@error != 0
					goto UNDO
			end
			else --enabling = 0
			begin
				if @originator_id = 0
					select @forcetabaug = 1
				else if @ispub = 0 and @tabrepobjsexists = 1
				begin
					delete from dbo.MSreplication_objects where object_name = @conftabname 
												and publisher = @publisher
												and publisher_db = @publisher_db
												and publication = @publication
												and article = @artname
												and object_type = N'U'

					if not exists (select * from dbo.MSreplication_objects where object_name = @conftabname 
																and object_type = N'U')
						select @forcetabaug = 1
				end
				
				if @forcetabaug = 1
				begin
					-- prefix with scheme name: dbo
					select @conftabname = N'[dbo].' + QUOTENAME(@conftabname)
					if object_id(@conftabname) is not NULL 
						exec ('drop table ' + @conftabname)  -- drop conflict table

					EXEC %%Object(MultiName = @fulltablename).LockMatchID(ID = @tabobjid, Exclusive = 1, BindInternal = 0)
					-- disabling: @replpeerid is 0, this will internally drop hidden column
					exec %%Relation(ID = @tabobjid).SetReplPeerId(Value = 0)
					if @@error != 0
						goto UNDO
				end
			end
		end

		fetch #harticle into @schname, @tabname, @artname, @schema_option 
	end --while

	if @cursor_opened = 1
	begin
		close #harticle
	end

	if @cursor_allocated = 1
	begin
		deallocate #harticle
	end 

	commit tran
	return (0)


UNDO:

	if @cursor_opened = 1
	begin
		close #harticle
	end

	if @cursor_allocated = 1
	begin
		deallocate #harticle
	end 

	rollback tran tr_tableaug
	commit tran

	raiserror(21542, 16, 1, @@error, 'sp_peerconflictdetection_tableaug')
	return (1)

end
GO
GRANT EXECUTE ON [sys].[sp_peerconflictdetection_tableaug] TO [public] AS [dbo]
GO
