SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddmergetriggers_from_template]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddmergetriggers_from_template] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddmergetriggers_from_template]
	@tablenickstr [nvarchar](15),
	@source_table [nvarchar](270),
	@table_owner [sysname],
	@rgcol [sysname],
	@column_tracking [int],
	@trigger_type [tinyint],
	@viewname [sysname],
	@tsview [sysname],
	@trigname [sysname],
	@genhistory_viewname [sysname],
	@replnick [binary](6),
	@max_colv_size_in_bytes_str [nvarchar](15)
WITH EXECUTE AS CALLER
AS
set nocount on
    

    declare @retcode int, @quoted_dbname nvarchar(258), @quoted_tableowner_dot nvarchar(259), @quoted_sourcetable nvarchar(258),
			@replnickstr nvarchar(20), @quoted_rgcol nvarchar(258), @colv_param1 nvarchar(10), @colv_param2 nvarchar(200),
			@colv_param3 nvarchar(200), 
			@quoted_trigname nvarchar(258), 
			@quoted_viewname nvarchar(264),
			@quoted_tsview nvarchar(264),
			@quoted_genhistory_viewname nvarchar(264),
			@tablenick int
    
    EXEC @retcode = dbo.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    
	-- Validate @tablenickstr is an int for usage in the dynamic sql below	
	select @tablenick = cast(@tablenickstr as int)
	if @@ERROR <> 0
		return(1)

    select @quoted_dbname = quotename(db_name()), 
			@quoted_tableowner_dot = case when @table_owner is not null then quotename(@table_owner) + N'.' else N'' end, 
			@quoted_sourcetable = case when @table_owner is not null then quotename(@source_table) else @source_table end,
			@quoted_trigname = quotename(@trigname),
			@quoted_viewname = '[dbo].' + quotename(@viewname),
			@quoted_tsview = '[dbo].' + quotename(@tsview),
			@quoted_genhistory_viewname = '[dbo].' + quotename(@genhistory_viewname),
			@replnickstr = sys.fn_varbintohexstr(@replnick), @quoted_rgcol = quotename(@rgcol), @colv_param1 = case when @column_tracking = 1 then '0xFF			' else 'NULL' end, @colv_param2 = case when @column_tracking = 1 then '
            set @cv = 0xFF
            set @cv = { fn UPDATECOLVBM(@cv, @replnick, @bm, @missingbm, { fn GETMAXVERSION(@lineage) }) } '
            else '
            set @cv = NULL ' end,
            @colv_param3 = case when @column_tracking = 0 then 'NULL' else '{ fn UPDATECOLVBM(colv1, @replnick, @bm, @missingbm, { fn GETMAXVERSION({ fn UPDATELINEAGE(lineage, @replnick, @oldmaxversion+1) }) }) }  ' end
        
    if @trigger_type = 0
    begin
		
		exec ('create trigger ' + @quoted_trigname + ' on ' + @quoted_dbname + '.' + @quoted_tableowner_dot + @quoted_sourcetable + ' for insert   as 
		declare @is_mergeagent bit, @retcode smallint 

		set rowcount 0
	    set transaction isolation level read committed

		select @is_mergeagent = convert(bit, sessionproperty(''replication_agent''))
	        
		if (select trigger_nestlevel()) = 1 and @is_mergeagent = 1
			return  
		declare @article_rows_inserted int
		select @article_rows_inserted =  count(*) from inserted 
		if @article_rows_inserted = 0 
			return
		declare @tablenick int, @rowguid uniqueidentifier
		, @replnick binary(6), @lineage varbinary(311), @colv1 varbinary(' + @max_colv_size_in_bytes_str + '), @cv varbinary(1)
		, @ccols int, @newgen bigint, @version int, @curversion int
		, @oldmaxversion int, @ts_rows_exist bit
		declare @dt datetime
		declare @nickbin varbinary(8)
		declare @error int 
		set nocount on
		set @tablenick = ' + @tablenickstr + '
		set @lineage = 0x0
		set @retcode = 0
		select @oldmaxversion= maxversion_at_cleanup from dbo.sysmergearticles where nickname = @tablenick
		select @dt = getdate()

		select @replnick = ' + @replnickstr + '  
		set @nickbin= @replnick + 0xFF

		select @newgen = NULL
		select top 1 @newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
			where art_nick = ' + @tablenickstr + '     and 
				  genstatus = 0
		if @newgen is NULL
		begin
			insert into ' + @quoted_genhistory_viewname + ' with (rowlock)
				(guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
				   values   (newid(), 0, @tablenick, @nickbin, @dt, @article_rows_inserted)
			select @error = @@error, @newgen = @@identity    
			if @error<>0 or @newgen is NULL
				goto FAILURE
		end
		set @lineage = { fn UPDATELINEAGE (0x0, @replnick, 1) }
				set @colv1 = ' + @colv_param1 + '
		if (@@error <> 0)
		begin
			goto FAILURE
		end

		select @ts_rows_exist = 0 
			select @ts_rows_exist = 1 where exists (select ts.rowguid from inserted i, ' + @quoted_tsview + ' ts with (rowlock) where ts.tablenick = @tablenick and ts.rowguid = i.rowguidcol)     
		if @ts_rows_exist = 1
		begin    
			select @version = max({fn GETMAXVERSION(lineage)}) from ' + @quoted_tsview + ' where 
				tablenick = @tablenick and rowguid in (select rowguidcol from inserted) 

			if @version is not null
			begin
				-- reset lineage and colv to higher version...
				set @curversion = 0
				while (@curversion <= @version)
				begin
					set @lineage = { fn UPDATELINEAGE (@lineage, @replnick, @oldmaxversion+1) }
					set @curversion= { fn GETMAXVERSION(@lineage) }
				end

				if (@colv1 IS NOT NULL)
					set @colv1 = { fn UPDATECOLVBM(@colv1, @replnick, 0x01, 0x00, { fn GETMAXVERSION(@lineage) }) }    
					delete from ' + @quoted_tsview + ' with (rowlock) where tablenick = @tablenick and rowguid in
						(select rowguidcol from inserted) 
			end
		end 
		
			insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen, marker) 
			select @tablenick, rowguidcol, @lineage, @colv1, @newgen, (-@newgen), NULL
			from inserted i where not exists
			(select rowguid from ' + @quoted_viewname + ' with (readcommitted, rowlock, readpast) where tablenick = @tablenick and rowguid = i.rowguidcol)  
		if @@error <> 0 
			goto FAILURE   

		return
	FAILURE:
		if @@trancount > 0
			rollback tran
		raiserror (20041, 16, -1)
		return 
		')

    end
    
    else if @trigger_type = 1
    begin
		exec ('create trigger ' + @quoted_trigname + ' on ' + @quoted_dbname + '.' + @quoted_tableowner_dot + @quoted_sourcetable + ' FOR UPDATE   AS 
		declare @is_mergeagent bit, @at_publisher bit, @retcode int 

		set rowcount 0
	    set transaction isolation level read committed

		select @is_mergeagent = convert(bit, sessionproperty(''replication_agent''))
		select @at_publisher = 0   
		declare @article_rows_updated int
		select @article_rows_updated = count(*) from inserted 
	    
		if @article_rows_updated=0
			return
		declare @contents_rows_updated int, @updateerror int, @rowguid uniqueidentifier
		, @bm varbinary(500), @missingbm varbinary(500), @lineage varbinary(311), @cv varbinary(' + @max_colv_size_in_bytes_str + ')
		, @tablenick int, @partchange int, @joinchange int, @logicalrelationchange int, @oldmaxversion int
		, @partgen bigint, @newgen bigint, @replnick binary(6)
		declare @dt datetime
		declare @nickbin varbinary(8)
		declare @error int 
		set nocount on

		set @tablenick = ' + @tablenickstr + '    
	    
		select @replnick = ' + @replnickstr + '   
		select @nickbin = @replnick + 0xFF
	    
		select @oldmaxversion = maxversion_at_cleanup from dbo.sysmergearticles where nickname = @tablenick
		select @dt = getdate()
	    
		-- Use intrinsic funtion to set bits for updated columns
		set @bm = columns_updated() 
		select @newgen = NULL
		select top 1 @newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
			where art_nick = ' + @tablenickstr + '     and 
				genstatus = 0 
		if @newgen is NULL
		begin
			insert into ' + @quoted_genhistory_viewname + ' with (rowlock)
			(guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
				   values   (newid(), 0, @tablenick, @nickbin, @dt, @article_rows_updated)
			select @error = @@error, @newgen = @@identity    
			if @error<>0 or @newgen is NULL
				goto FAILURE
		end 

		/* save a copy of @bm */
		declare @origin_bm varbinary(500)
		set  @origin_bm =  @bm

		/* only do the map down when needed */
		set @missingbm = 0x00 
		if update(' + @quoted_rgcol + ')
		begin
			if @@trancount > 0
				rollback tran
	                
			RAISERROR (20062, 16, -1)
		end  
		else    
			set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) } ' + 
			@colv_param2 + '
            
			set @partgen = NULL 
			update ' + @quoted_viewname + ' with (rowlock)
			set lineage = { fn UPDATELINEAGE(lineage, @replnick, @oldmaxversion+1) }, 
				generation = @newgen, 
				partchangegen = case when (@partchange = 1 or @joinchange = 1) then @newgen else partchangegen end, 
	            
					colv1 = ' + @colv_param3 + '
			FROM inserted as I JOIN ' + @quoted_viewname + ' as V with (rowlock)
			ON (I.rowguidcol=V.rowguid)
			and V.tablenick = @tablenick
			option (force order, loop join)

			select @updateerror = @@error, @contents_rows_updated = @@rowcount 
	          
			if @article_rows_updated <> @contents_rows_updated
			begin  
				insert into ' + @quoted_viewname + ' with (rowlock) (tablenick, rowguid, lineage, colv1, generation, partchangegen) 
				select @tablenick, rowguidcol, @lineage, @cv, @newgen, @partgen
				from inserted i 
				where not exists (select rowguid from ' + @quoted_viewname + ' with (readcommitted, rowlock, readpast) where tablenick = @tablenick and rowguid = i.rowguidcol)     
				if @@error <> 0
					GOTO FAILURE
			end     

		return
	FAILURE:
		if @@trancount > 0
			rollback tran
		raiserror (20041, 16, -1)
		return 

		')
    end
    
    else if @trigger_type = 2 
    begin
		exec ('create trigger ' + @quoted_trigname + ' on ' + @quoted_dbname + '.' + @quoted_tableowner_dot + @quoted_sourcetable + ' FOR DELETE   AS 
		declare @is_mergeagent bit, @at_publisher bit, @retcode smallint 

		set rowcount 0
	    set transaction isolation level read committed

		select @is_mergeagent = convert(bit, sessionproperty(''replication_agent''))
		select @at_publisher = 0 
		declare @article_rows_deleted int
		select @article_rows_deleted = count(*) from deleted
		if @article_rows_deleted=0
			return
		declare @tablenick int, @replnick binary(6), 
				@lineage varbinary(311), @newgen bigint, @oldmaxversion int,
				@rowguid uniqueidentifier 
		declare @dt datetime, @nickbin varbinary(8), @error int
	     
		set nocount on
		select @tablenick = ' + @tablenickstr + '    
		if @article_rows_deleted = 1 select @rowguid = rowguidcol from deleted
		select @oldmaxversion= maxversion_at_cleanup from dbo.sysmergearticles where nickname = @tablenick
		select @dt = getdate()

		select @replnick = ' + @replnickstr + '  
		set @nickbin= @replnick + 0xFF

		select @newgen = NULL
		select top 1 @newgen = generation from ' + @quoted_genhistory_viewname + ' with (rowlock, updlock, readpast) 
			where art_nick = ' + @tablenickstr + '          
				  and genstatus = 0
		if @newgen is NULL
		begin
			insert into ' + @quoted_genhistory_viewname + '  with (rowlock)
				(guidsrc, genstatus, art_nick, nicknames, coldate, changecount)
				 values (newid(), 0, @tablenick, @nickbin, @dt, @article_rows_deleted)
			select @error = @@error, @newgen = @@identity    
			if @error<>0 or @newgen is NULL
				goto FAILURE
		end  
		set @lineage = { fn UPDATELINEAGE(0x0, @replnick, @oldmaxversion+1) }  
		if @article_rows_deleted = 1
			insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation)
				select @rowguid, @tablenick, 1, isnull((select { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) } from 
				' + @quoted_viewname + ' c with (rowlock) where c.tablenick = @tablenick and c.rowguid = @rowguid),@lineage), @newgen
		else
			insert into ' + @quoted_tsview + ' with (rowlock) (rowguid, tablenick, type, lineage, generation)
				select d.rowguidcol, @tablenick, 1, { fn UPDATELINEAGE(COALESCE(c.lineage, @lineage), @replnick, @oldmaxversion+1) }, @newgen from 
				deleted d left outer join ' + @quoted_viewname + ' c with (rowlock) on c.tablenick = @tablenick and c.rowguid = d.rowguidcol 
	             
		if @@error <> 0
			GOTO FAILURE  
			delete ' + @quoted_viewname + '  with (rowlock)
			from deleted d, ' + @quoted_viewname + ' cont with (rowlock)
			where cont.tablenick = @tablenick and cont.rowguid = d.rowguidcol
			option (force order, loop join)

		if @@error <> 0
			GOTO FAILURE

	    
		return
	FAILURE:
		if @@trancount > 0
			rollback tran
		raiserror (20041, 16, -1)
		return 

		')
    end
    
    if @@error <> 0
		return 1
		
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSaddmergetriggers_from_template] TO [public] AS [dbo]
GO
