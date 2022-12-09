SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_estimate_data_compression_savings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_estimate_data_compression_savings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_estimate_data_compression_savings]
	@schema_name [sysname],
	@object_name [sysname],
	@index_id [int],
	@partition_number [int],
	@data_compression [nvarchar](60)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on;

	if (SERVERPROPERTY ('EngineEdition') NOT IN (2 /* Standard */, 3 /* Enterprise */, 4 /* Express */, 8 /*Cloud Lifter */))
	begin
		declare @procName sysname = N'sp_estimate_data_compression_savings';
		declare @procNameLen int = datalength(@procName);
		
		declare @instanceName sysname = ISNULL(CONVERT(sysname, SERVERPROPERTY('InstanceName')), N'MSSQLSERVER');
		declare @instanceNameLen int = datalength(@instanceName);
		
		raiserror(534, -1, -1, @procNameLen, @procName, @instanceNameLen, @instanceName);
		return @@error;
	end

	-- Check @schema_name parameter
	declare @schema_id int 
	if (@schema_name is null)
		set @schema_id = schema_id()
	else 
		set @schema_id = schema_id(@schema_name)

	if (@schema_id is null)
	begin
		raiserror(15659, -1, -1, @schema_name);
		return @@error;
	end
	-- Set the schema name to the default schema
	if (@schema_name is null)
		set @schema_name = schema_name(@schema_id);

	-- check object name
	if (@object_name is null)
	begin
		raiserror(15223, -1, -1, 'object_name');
		return @@error;
	end
	
	-- Check if the object name is a temporary table
	if (substring(@object_name, 1, 1) = '#')
	begin
		raiserror(15661, -1, -1);
		return @@error;
	end

	-- Verify that the object exists and that the user has permission to see it.
	declare @object_id int = object_id(quotename(@schema_name) + '.' + quotename(@object_name));
	declare @object_len int;
	if (@object_id is null)
	begin
		set @object_len = datalength(@object_name);
		raiserror(1088, -1, -1, @object_len, @object_name);
		return @@error;
	end

	-- Check object type. Must be user table or view.
	if (not exists (select * from sys.objects where object_id = @object_id and (type = 'U' or type = 'V')))
	begin
		raiserror(15001, -1, -1, @object_name);
		return @@error;
	end

	-- Check SELECT permission on table. The check above fails if the user has no permissions
	-- on the table, so this check applies only if the user has some permission other than
	-- SELECT (e.g., INSERT) but not SELECT itself.
	if has_perms_by_name(quotename(@schema_name) + '.' + quotename(@object_name), 'object', 'select') = 0
	begin
		declare @db_name sysname = db_name();
		declare @db_len int = datalength(@db_name), @schema_len int = datalength(@schema_name);
		set @object_len = datalength(@object_name);
		raiserror(229, -1, -1, N'SELECT', @object_len, @object_name, @db_len, @db_name, @schema_len, @schema_name);
		return @@error;
	end

	-- Check for sparse columns or column sets.
	declare @sparse_columns_and_column_sets int = (select count(*) from sys.columns where object_id = @object_id and (is_sparse = 1 or is_column_set = 1));
	if (@sparse_columns_and_column_sets > 0)
	begin
		raiserror(15662, -1, -1);
		return @@error;
	end

	-- check data compression
	if (@data_compression is null)
	begin
		raiserror(15223, -1, -1, 'datacompression');
		return @@error;
	end

	set @data_compression = upper(@data_compression);
	if (@data_compression not in ('NONE', 'ROW', 'PAGE', 'COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
	begin
		raiserror(3217, -1, -1, 'datacompression');
		return @@error;
	end

	if (@index_id is not null)
	begin
		declare @index_type int = null;
		select @index_type = type from sys.indexes with (nolock) where object_id = @object_id and index_id = @index_id;

		if (@index_type is null)
		begin
			raiserror(15323, -1, -1, @object_name);
			return @@error;
		end

		if (@index_type not in (0, 1, 2, 5, 6))
		begin
			-- Currently do not support XML and spatial, and hash indexes
			raiserror(15660, -1, -1);
			return @@error;
		end
	end
	
	declare @desired_compression int = case @data_compression when 'NONE' then 0 when 'ROW' then 1 when 'PAGE' then 2 when 'COLUMNSTORE' then 3 else 4 end;

	-- Hard coded sample table and indexes that we will use
	declare @sample_table nvarchar(256) = '#sample_tableDBA05385A6FF40F888204D05C7D56D2B';
	declare @dummy_column nvarchar(256) = 'dummyDBA05385A6FF40F888204D05C7D56D2B';
	declare @sample_index nvarchar(256) = 'sample_indexDBA05385A6FF40F888204D05C7D56D2B';
	declare @pages_to_sample int = 5000;

	-- Find all the partitions and their partitioning info that we need
	select	i.index_id, p.partition_number, p.data_compression, p.data_compression_desc, 
			ic.column_id as [partition_column_id], f.function_id as [partition_function_id],
			case
				when exists	(
								--
								-- Clustered Columnstore supports only computed non-persisted column, all others are not supported, but this still results in 0
								-- For heap, it always 0, for nonclustered/clustered index, it's always required for non-persisted computed column.
								select 1
								from sys.computed_columns c with (nolock)
								join sys.index_columns ic with (nolock) 
									on ic.object_id = c.object_id
									and ic.column_id = c.column_id
									and c.is_persisted = 0
								where ic.index_id = i.index_id
							) 
				then 1
				else 0
			end
			as requires_computed, drop_current_index_ddl, drop_desired_index_ddl, create_current_index_ddl, create_desired_index_ddl,
			compress_current_ddl, compress_desired_ddl, is_primary
	into #index_partition_info
	from sys.partitions p with (nolock)
	join sys.indexes i with (nolock) 
		on p.object_id = i.object_id
		and p.index_id = i.index_id
	left join 	(
					select *
					from sys.index_columns with (nolock)
					where partition_ordinal = 1
				) ic
		on p.object_id = ic.object_id 
		and i.index_id = ic.index_id
	left join sys.partition_schemes ps with (nolock)
		on ps.data_space_id = i.data_space_id
	left join sys.partition_functions f with (nolock)
		on f.function_id = ps.function_id
	cross apply sys.generate_index_ddl(@object_id, i.index_id, p.data_compression, @sample_table, @sample_index, @desired_compression)
	where p.object_id = @object_id 
		and i.is_disabled = 0 and i.is_hypothetical = 0
		--
		-- Filter on index and/or partition if these were provided - always include the clustered index if there is one
		--
		and i.type <= 6 and i.type not in (3, 4) -- ignore XML, Extended indexes for now
		and	(
				i.index_id = case 
							when @index_id is null
							then i.index_id 
							else @index_id 
							end or i.index_id = 1	-- Index_id=1 is always included if exists.
			)
		and p.partition_number = case
								when @partition_number is null
								then p.partition_number
								else @partition_number
								end
	order by i.index_id
	  
	--
	-- If the user requested to estimate compression of a view that isn't indexed, we will not have anything in #index_partition_info
	--
	if (0 = (select count(*) from #index_partition_info))
	begin
		raiserror(15001, -1, -1, @object_name);
		return @@error;
	end

	--
	-- Find all the xml schema collections used by the table
	--
	select	'use tempdb; create xml schema collection ' + quotename(N'schema_' + convert(nvarchar(10), xml_collection_id)) +
		' as N''' + replace(convert(nvarchar(max), xml_schema_namespace(schema_name, name)), N'''', N'''''') + '''' as create_ddl,
		'use tempdb; drop xml schema collection ' + quotename(N'schema_' + convert(nvarchar(10), xml_collection_id)) as drop_ddl
	into #xml_schema_ddl
	from 
	(
		select distinct c.xml_collection_id, xsc.name, s.name as schema_name
		from sys.columns c with (nolock) 
		join sys.xml_schema_collections xsc with (nolock) on c.xml_collection_id = xsc.xml_collection_id
		join sys.schemas s with (nolock) on xsc.schema_id = s.schema_id
		where c.object_id = @object_id and c.xml_collection_id <> 0
	) t

	--
	-- create required xml schema collections
	--
	declare c cursor local fast_forward for select create_ddl from #xml_schema_ddl
	open c;
	declare @create_ddl nvarchar(max)
	fetch next from c into @create_ddl;
	while @@fetch_status = 0
	begin
		exec(@create_ddl);

		fetch next from c into @create_ddl;
	end;
	close c;
	deallocate c;	

	-- Create results table
	create table #estimated_results ([object_name] sysname, [schema_name] sysname, [index_id] int, [partition_number] int,
									[size_with_current_compression_setting(KB)] bigint, [size_with_requested_compression_setting(KB)] bigint,
									[sample_size_with_current_compression_setting(KB)] bigint, [sample_size_with_requested_compression_setting(KB)] bigint);
	
	--
	-- Outer Loop - Iterate through each unique partition sample
	-- Iteration does not have to be in any particular order, the results table will sort that out
	--
	declare c cursor local fast_forward for 
		select	partition_column_id, partition_function_id, partition_number, requires_computed,
				alter_ddl, insert_ddl, table_option_ddl
		from	(
					select distinct partition_column_id, partition_function_id, partition_number, requires_computed
					from #index_partition_info
				)	t
		cross apply	(
						select case
									when used_page_count <= @pages_to_sample
									then 100
									else 100. * @pages_to_sample / used_page_count
									end as sample_percent
						from sys.dm_db_partition_stats ps
						where	ps.object_id = @object_id
							and index_id < 2 
							and ps.partition_number = t.partition_number) ps
		cross apply sys.generate_table_sample_ddl(
													@object_id, @schema_name, @object_name, partition_number, partition_column_id, 
													partition_function_id, @sample_table, @dummy_column, requires_computed, sample_percent
												)
	open c;

	declare @curr_partition_column_id int, @curr_partition_function_id int, @curr_partition_number int, 
            @requires_computed bit, @alter_ddl nvarchar(max), @insert_ddl nvarchar(max), @table_option_ddl nvarchar(max);
	fetch next from c into @curr_partition_column_id, @curr_partition_function_id, @curr_partition_number, 
						   @requires_computed, @alter_ddl, @insert_ddl, @table_option_ddl;
	while @@fetch_status = 0
	begin
		-- Step 1. Create the sample table in current scope
		-- 
		create table [#sample_tableDBA05385A6FF40F888204D05C7D56D2B]([dummyDBA05385A6FF40F888204D05C7D56D2B] [int]);

		-- Step 2. Add columns into sample table
		-- 
		exec (@alter_ddl);

		alter table [#sample_tableDBA05385A6FF40F888204D05C7D56D2B] rebuild
		
		exec (@table_option_ddl);
	
		-- @insert_ddl
		-- 
		exec (@insert_ddl);
		
		--
		-- Step 3.   Inner Loop:
		--			 Iterate through the indexes that use this sampled partition
		--
		declare index_partition_cursor cursor local fast_forward for 
		select 	ipi.index_id, ipi.data_compression, ipi.drop_current_index_ddl, ipi.drop_desired_index_ddl, ipi.create_current_index_ddl, 
				ipi.create_desired_index_ddl, ipi.compress_current_ddl, ipi.compress_desired_ddl, 
				ipi.is_primary
		from 	#index_partition_info ipi
		where 	(ipi.partition_column_id = @curr_partition_column_id or (ipi.partition_column_id is null and @curr_partition_column_id is null))
			and (partition_function_id = @curr_partition_function_id or (partition_function_id is null and @curr_partition_function_id is null))
			and (ipi.partition_number = @curr_partition_number or (ipi.partition_number is null and @curr_partition_number is null))
			and ipi.requires_computed = @requires_computed
		open	index_partition_cursor;

		declare @sample_table_object_id int = object_id('tempdb.dbo.#sample_tableDBA05385A6FF40F888204D05C7D56D2B');
		declare	@curr_index_id int, @cur_data_compression int, @drop_current_index_ddl nvarchar(max), @drop_desired_index_ddl nvarchar(max);
		declare	@compress_current_ddl nvarchar(max), @compress_desired_ddl nvarchar(max), @is_primary bit;
		declare	@create_current_index_ddl nvarchar(max), @create_desired_index_ddl nvarchar(max);
		
		fetch next
		from	index_partition_cursor 
		into	@curr_index_id, @cur_data_compression, @drop_current_index_ddl, @drop_desired_index_ddl, @create_current_index_ddl, 
				@create_desired_index_ddl, @compress_current_ddl, @compress_desired_ddl, @is_primary;

		while	@@fetch_status = 0
		begin
			declare @current_size bigint, @sample_compressed_current bigint, @sample_compressed_desired bigint;
			declare @require_drop_current_index bit = 0, @require_drop_desired_index bit = 0, @current_index_type int = null;

			-- Get Partition's current size
			set @current_size = 
				(
					select	used_page_count 
					from	sys.dm_db_partition_stats 
					where	object_id = @object_id 
						and index_id = @curr_index_id 
						and partition_number = @curr_partition_number
				);

			set @current_index_type = 
				(
					select type from sys.indexes with (nolock) where object_id = @object_id and index_id = @curr_index_id
				);
				
			--
			-- Create the index
			--
			if (@create_current_index_ddl is not null)
			begin
				exec (@create_current_index_ddl);
				set @require_drop_current_index = 1;
			end;

			--
			-- With current compression setting, sample_index_id should always be same to current_index_id in case of heap/clustered index, else it's whatever 
			-- the one currently created on sample table.
			--
			declare @sample_index_id int = case 
					when @curr_index_id = 0 then 0 -- heap
					when @curr_index_id = 1 then 1 -- clustered index
					else 
					(
						select index_id from tempdb.sys.indexes with (nolock)
						where object_id = @sample_table_object_id and index_id <> 0 and index_id <> 1
					)
					-- In all other cases, there should only be one index
					end;

			--
			-- Compress to current compression level
			--
			if @compress_current_ddl is not null
			begin
				exec (@compress_current_ddl);
			end;

			--
			-- Get sample's size at current compression level
			select @sample_compressed_current = used_page_count 
			from tempdb.sys.dm_db_partition_stats
			where object_id = @sample_table_object_id and index_id = @sample_index_id;
			
			
			--
			-- create desired index, under these conditions below a desired index must be created.
			-- 1. estimate a rowstore compression setting from columnstore compression setting or the opposite way, in which case the create_desired_index_ddl is non-empty.
			-- 2. estimate a clustered columnstore with desired rowstore compression setting, in which case the create_desired_index_ddl is empty because a heap will be used for compare,
			--    but the existing index on the sample table must also be dropped.
			--
			if (@create_desired_index_ddl is not null) or (@current_index_type = 5 and @desired_compression not in (3, 4))
			begin
				if (@require_drop_current_index <> 0 and @drop_current_index_ddl is not null)
				begin
					exec (@drop_current_index_ddl);
					set @require_drop_current_index = 0;
				end

				if @create_desired_index_ddl is not null
				begin
					exec (@create_desired_index_ddl);

					set @require_drop_desired_index = 1;
			
					--
					-- If we have to create the desired index type, we have to update the sample_index_id.
					--
					-- we evaluate one index at most each time for desired compression setting, set sample_index_id as what the table has.
					--
					set @sample_index_id =
						(
							select index_id from tempdb.sys.indexes with (nolock)
							where object_id = @sample_table_object_id and index_id <> 0
						);
				end
				else
				begin
						set @sample_index_id = 0;	-- desired compression setting is merely on a heap
				end
			end
				
			-- Compress to target level
			--
			if @compress_desired_ddl is not null
			begin
				exec (@compress_desired_ddl);
			end

			-- Get sample's size at desired compression level
			select @sample_compressed_desired = used_page_count 
			from tempdb.sys.dm_db_partition_stats 
			where object_id = @sample_table_object_id and index_id = @sample_index_id;

			
			--
			-- Final cleanup of created indexes.
			--
			if (@require_drop_current_index <> 0 and @drop_current_index_ddl is not null)
			begin
				exec (@drop_current_index_ddl);
				set @require_drop_current_index = 0;
			end
			
			if (@require_drop_desired_index <> 0 and @drop_desired_index_ddl is not null)
			begin
				exec (@drop_desired_index_ddl);
				set @require_drop_desired_index = 0;
			end

			--
			-- if the current setting and requested setting are the same, show how much we would save if we discount fragmentation and new
			-- compression schemes (like unicode compression). In these cases, we use the sample size or the current size of the table as
			-- starting point, instead of the temp table that was created
			--
			-- we don't know exactly how many pages of secondary index being sampled, sample_percent is based on base table size, there is no way to
			-- compute how much defragmentation to obtain.
			-- 			
			-- Sometimes even with same data compression setting, page number of sample_compressed_current can be more than actual pages sampled, in which case 
			-- the number of pages after compressing is based on the data being sampled, so it's kind of hard to predict how much we can discount fragmentation.
			-- to
			--
			if (@cur_data_compression = @desired_compression and @curr_index_id < 2) -- pages_to_sample is related to base table only
			begin
				if (@current_size > @pages_to_sample)
				begin
					if (@sample_compressed_current < @pages_to_sample)		-- Try to estimate after discounts fragmentation, only when it possibly exists(may still depends on data being compressed)
					begin
						set @sample_compressed_current = @pages_to_sample
					end
				end
				else
				begin
					if(@sample_compressed_current < @current_size)
					begin
						set @sample_compressed_current = @current_size
					end
				end
			end

			declare @estimated_compressed_size bigint = 
			case @sample_compressed_current
			when 0 then 0
			else @current_size * ((1. * cast (@sample_compressed_desired as float)) / @sample_compressed_current)
			end;

			if (@index_id is null or @curr_index_id = @index_id)
			begin
			insert into #estimated_results values (@object_name, @schema_name, @curr_index_id, @curr_partition_number,
					@current_size * 8, @estimated_compressed_size * 8, @sample_compressed_current * 8, @sample_compressed_desired * 8);
			end

			fetch next from index_partition_cursor into @curr_index_id, @cur_data_compression, @drop_current_index_ddl, @drop_desired_index_ddl,
							@create_current_index_ddl, @create_desired_index_ddl, @compress_current_ddl, @compress_desired_ddl, @is_primary;
		end;
		close index_partition_cursor;
		deallocate index_partition_cursor;

		--
		-- Step 4. Drop the sample table
		--
		drop table [#sample_tableDBA05385A6FF40F888204D05C7D56D2B];

		fetch next from c into @curr_partition_column_id, @curr_partition_function_id, @curr_partition_number, 
							   @requires_computed, @alter_ddl, @insert_ddl, @table_option_ddl;
	end
	close c;
	deallocate c;	

	--
	-- drop xml schema collection
	--
	declare c cursor local fast_forward for select drop_ddl from #xml_schema_ddl
	open c;
	declare @drop_ddl nvarchar(max)
	fetch next from c into @drop_ddl;
	while @@fetch_status = 0
	begin
		exec(@drop_ddl);

		fetch next from c into @drop_ddl;
	end;
	close c;
	deallocate c;	

	select * from #estimated_results;

	drop table #estimated_results;
	drop table #xml_schema_ddl;
end
GO
GRANT EXECUTE ON [sys].[sp_estimate_data_compression_savings] TO [public] AS [dbo]
GO
