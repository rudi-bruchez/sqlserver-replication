SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replsqlqgetrows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replsqlqgetrows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replsqlqgetrows]
	@publisher [sysname],
	@publisherdb [sysname],
	@publication [sysname],
	@batchsize [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	set implicit_transactions off
	declare @retcode int
	declare @nomesgs TABLE (tranid sysname, datalen int, data varbinary(8000),
			commandtype int, insertdate datetime, orderkey bigint, cmdstate bit)
	--
	-- Security check
	--
	exec @retcode = sp_MSreplcheck_subscribe
	if @@error != 0 or @retcode != 0
		return 1
	--
	-- does the queue table exist
	--
	if exists (select * from sys.objects where name = 'MSreplication_queue')
	begin
		declare @totcommandcount bigint
				,@trancount bigint
				,@tranid sysname
				,@curtrancommandcount bigint
				, @batchcount bigint
		declare @trantab table (tranid sysname primary key)
		--
		-- does the tran info table exist
		--
		if not exists (select * from sys.objects where name = 'MSrepl_queuedtraninfo')
		begin
			--
			-- tran info table does not exist - create and populate it
			--
			exec @retcode = sp_MScreate_sub_tables_internal
				@tran_sub_table = 0,
				@property_table = 0,
				@sqlqueue_table = 1
			if  (@@error != 0 or @retcode != 0)
				return 1
		end	
		--
		-- At this point both queue table and tran info table exist
		-- check the command count
		--
		select @totcommandcount = sum(commandcount)
			,@trancount = count(tranid)
		from dbo.MSrepl_queuedtraninfo with (READPAST)
		where publisher = UPPER(@publisher)
			and publisher_db = @publisherdb 
			and publication = @publication

		if (@trancount = 0)
		begin
			--
			-- no committed transactions
			-- send empty rowset
			--
			select * from @nomesgs
		end
		else		
		begin
			--
			-- prepare a list of transactions to read
			--
			select @batchcount = 0
			declare #htcdataseq cursor local for
				select tranid, commandcount
				from dbo.MSrepl_queuedtraninfo with (READPAST) 
				where publisher = UPPER(@publisher) 
					and publisher_db = @publisherdb 
					and publication = @publication
				order by maxorderkey asc
			open #htcdataseq
			fetch #htcdataseq into @tranid, @curtrancommandcount
			if (@@error != 0)
				return 1
			while (@@fetch_status != -1)
			begin
				--
				-- Are we done
				--
				if (@batchcount > @batchsize)
				begin
					--
					-- we are done selecting the transactions to process
					--
					break
				end
				else
				begin
					--
					-- include this transaction
					-- update the batch counter
					--
					insert into @trantab (tranid) values (@tranid)
					if (@@error != 0)
						return 1
					select @batchcount = @batchcount + @curtrancommandcount
				end
				--
				-- fetch next transaction to process
				--
				fetch #htcdataseq into @tranid, @curtrancommandcount
			end
			close #htcdataseq
			deallocate #htcdataseq
			if (@@error != 0)
				return 1
			--
			-- do the join for the select transactions
			-- select the transactions in the order they were committed (maxorderkey ascending).
			-- for each transaction - the commands are ordered using orderkey (ascending)
			-- we do not want to take any locks to block the commit(delete) operations on queue
			--
			select q.tranid, q.datalen, q.data, q.commandtype, q.insertdate, q.orderkey, q.cmdstate 
			from (dbo.MSreplication_queue as q with (NOLOCK) 
				join (dbo.MSrepl_queuedtraninfo as t with (NOLOCK)
					join @trantab as tt
					on t.tranid = tt.tranid collate database_default) 
				on q.publisher = t.publisher
					and q.publisher_db = t.publisher_db 
					and q.publication = t.publication
					and q.tranid = t.tranid)
			where t.publisher = UPPER(@publisher)
				and t.publisher_db = @publisherdb 
				and t.publication = @publication
			order by t.maxorderkey asc, q.orderkey asc
		end -- else block for if (@trancount = 0)
	end -- if block for exists MSreplication_queue
	else
	begin
		--
		-- Queue table does not exist
		-- send empty rowset
		--
		select * from @nomesgs
	end	
	--
	-- check error
	--
	if (@@error != 0)
		return 1
	--
	-- All done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replsqlqgetrows] TO [public] AS [dbo]
GO
