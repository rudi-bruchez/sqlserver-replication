SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatelightweightmultipurposeproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatelightweightmultipurposeproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatelightweightmultipurposeproc]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @postfix			nchar(32)
	declare @qualified_name		nvarchar(270)
	declare @destination_owner	sysname
	declare @destination_object	sysname
	declare @tablenick			int
	declare @tablenickstr		nvarchar(20)
	declare @retcode			int
	declare @objid				int
	declare @column_tracking	bit
	declare @columnordinal		int
	declare @previouscolid		int
	declare @colid				int
	declare @colname			sysname
	declare @cmdpiece			nvarchar(4000)
	declare @from_clause		nvarchar(4000)
	declare @columnlist 		nvarchar(max)
	declare @cmdtable			table (phase int not null, 
							   		   step int identity not null, 
									   cmdtext nvarchar(4000) collate database_default null)
	create table #columnvaluequery	(step int identity not null, 
									 cmdtext nvarchar(4000) collate database_default null)

	-- Security check
	exec @retcode= sys.sp_MSreplcheck_subscribe
	if @@error <> 0 or @retcode <> 0 return (1)

	select @destination_object= destination_object, 
		   @tablenick= nickname,
		   @postfix= procname_postfix, 
		   @destination_owner= destination_owner,
		   @column_tracking= column_tracking,
		   @objid= objid
		from dbo.sysmergearticles 
		where pubid = @pubid and artid = @artid

	if @destination_owner is null or @destination_owner=''
		set @qualified_name= quotename(@destination_object)
	else
		set @qualified_name= quotename(@destination_owner) + '.' + quotename(@destination_object)

	set @tablenickstr= cast(@tablenick as nvarchar(20))

	-- Determine the base table column list, excluding computed or timestamp colums.
	-- Used for @action=1,2,6
	if not exists (select * from sys.columns
						where object_id = @objid and 
							  (
								is_computed = 1 
								or
								system_type_id = type_id('timestamp')
							  ))
	begin
		set @columnlist= 't.*'
	end
	else
	begin
		set @columnordinal= 0
		set @previouscolid= -1
		while (1=1)
		begin
			set @columnordinal= @columnordinal + 1
			
			set @colid= (select min(column_id) from sys.columns 
							where object_id = @objid and 
								  column_id > @previouscolid and
								  is_computed = 0 and
								  system_type_id <> type_id('timestamp'))
		
			if @colid is null
				break
		
			set @previouscolid= @colid
		
			select @colname= quotename(name)
				from sys.columns 
				where object_id = @objid and column_id = @colid

			if 1=@columnordinal
			begin
				set @columnlist= 't.' + @colname
			end
			else
			begin
				set @columnlist= @columnlist + ', t.' + @colname
			end
		end
	end

	set @from_clause= '
				from ' + @qualified_name + ' as t
						inner join 
						dbo.MSmerge_rowtrack as rt on t.rowguidcol = rt.rowguid
				where rt.tablenick = @tablenick and
					  rt.rowguid > @rowguid and
					  rt.changetype in (@METADATA_TYPE_InsertLightweight,
					  					@METADATA_TYPE_UpdateLightweight) and
					  rt.sync_cookie = @pubnick
				order by rt.rowguid asc
			if @@error <> 0 return 1
		'

	-- Generate query part that return actual column values for changed columns,
	-- null for unmodified columns.
	if 1=@column_tracking
	begin
		exec @retcode= sys.sp_MSgenerate_enumchangedcolumnvalues_query
								@objid= @objid

		if @@error <> 0 or @retcode <> 0 return 1
	end

	-- Procedure head.
	set @cmdpiece= '
create procedure dbo.' + quotename('MSmerge_lws_sp_multi_' + @postfix) + '
	@action			tinyint,
	@pubnick		int= null,
	@rowguid		uniqueidentifier= null,
	@type			tinyint= null output,
	@rowvector		varbinary(11)= null output,
	@changedcolumns	varbinary(128)= null output,
	@columns_enumeration tinyint= null output,
	@baserowexists	bit= null output,
	@maxrows        bigint= null
as
	set nocount on

	declare @retcode int
	declare @tablenick int
	declare @METADATA_TYPE_Missing tinyint
	declare @METADATA_TYPE_ContentsDeferred tinyint
	declare @METADATA_TYPE_InsertLightweight tinyint
	declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @COLUMNS_ENUMERATED_ChangedOnly tinyint
	declare @COLUMNS_ENUMERATED_AllOnConflictOrError tinyint
	declare @COLUMNS_ENUMERATED_AllOnOtherReason tinyint

	set @METADATA_TYPE_Missing= 0
	set @METADATA_TYPE_ContentsDeferred= 3
	set @METADATA_TYPE_InsertLightweight= 7 
	set @METADATA_TYPE_UpdateLightweight= 8
	set @COLUMNS_ENUMERATED_ChangedOnly= 0
	set @COLUMNS_ENUMERATED_AllOnConflictOrError= 1
	set @COLUMNS_ENUMERATED_AllOnOtherReason= 2
	set @retcode= 0

	-- Security check
	if (is_member(''db_owner'') <> 1)
	begin
		raiserror(15247,-1,-1)
		return (1)
	end

	select @tablenick= ' + @tablenickstr

	insert into @cmdtable (phase, cmdtext) values (0, @cmdpiece)

	-- @action=1 (retrieve row data)
	set @cmdpiece= '

	if @action = 1
	begin
		select ' + @columnlist + ' from ' + @qualified_name + ' t where rowguidcol = @rowguid
		if @@error <> 0 return 1
	end
	else if @action = 2
	begin
'

	insert into @cmdtable (phase, cmdtext) values (1, @cmdpiece)

	-- @action=2 (retrieve row data and metadata)
	-- If we enumerate all columns we use a 'select *' on the base table; if only
	-- changed columns are enumerated, use the result from #columnvaluequery.
	--
	-- IMPORTANT: If the number of metadata colums changes, adjust cMetadataColumnsLightweight accordingly!

	if 1=@column_tracking
	begin
		set @cmdpiece= '
		select top (@maxrows)
	       rt.tablenick, 
		   rt.rowguid, 
		   rt.rowvector, 
		   rt.changedcolumns,
		   rt.columns_enumeration,
		   rt.changetype,'

		insert into @cmdtable (phase, cmdtext) values (2, @cmdpiece)

		-- Insert the query that checks for changed columns.
		insert into @cmdtable (phase, cmdtext)
			select 3, cmdtext from #columnvaluequery order by step asc

		insert into @cmdtable (phase, cmdtext) values (4, @from_clause)
	end -- 1=@column_tracking
	else
	begin
		set @cmdpiece= '
		select top (@maxrows)
            rt.tablenick, 
            rt.rowguid, 
            rt.rowvector, 
            rt.changedcolumns,
            rt.columns_enumeration,
            rt.changetype,
			   ' + @columnlist

		insert into @cmdtable (phase, cmdtext) values (5, @cmdpiece)
		insert into @cmdtable (phase, cmdtext) values (6, @from_clause)
	end

	-- @action=3: determine metadata type, possibly retrieve row metadata
	set @cmdpiece= '
	end
	else if @action = 3
	begin
		set @type= @METADATA_TYPE_Missing
		set @rowvector= null
		
		-- Transaction and the serializable hint makes sure the row does not change its
		-- metadata type between querying the metadata and the base data. Otherwise, we might
		-- return a wrong metadata type.

		begin tran
			select top 1 @type= changetype, 
						 @rowvector= rowvector, 
						 @changedcolumns=  changedcolumns,
						 @columns_enumeration= columns_enumeration
						 
				from dbo.MSmerge_rowtrack with (serializable)
				where tablenick = @tablenick and rowguid = @rowguid

			if @type = @METADATA_TYPE_Missing
			begin
				-- There is no row metadata, but the base row might still be here.
				if exists (select top 1 * from ' + @qualified_name + ' where rowguidcol = @rowguid)
				begin
					set @type= @METADATA_TYPE_ContentsDeferred
				end
				if @@error <> 0 set @retcode= 1

				-- Set @columns_enumeration to the default value.
				set @columns_enumeration= @COLUMNS_ENUMERATED_AllOnOtherReason
			end

		commit tran
	end
	'

	insert into @cmdtable (phase, cmdtext) values (8, @cmdpiece)

	-- @action=4: lock base table
	set @cmdpiece= '
	else if @action = 4
	begin
		select 1 from ' + @qualified_name + ' with (tablock holdlock) where 1 = 2
		if @@error <> 0 set @retcode= 1
	end
	'

	insert into @cmdtable (phase, cmdtext) values (9, @cmdpiece)

	-- @action=5: check whether row exists in base table
	set @cmdpiece= '
	else if @action = 5
	begin
		if exists (select * from ' + @qualified_name + '  where rowguidcol = @rowguid)
		begin
			set @baserowexists= 1
		end
		else
		begin
			set @baserowexists= 0
		end

		if @@error <> 0 set @retcode= 1
	end
	'

	insert into @cmdtable (phase, cmdtext) values (10, @cmdpiece)

	-- @action=6: column information
	set @cmdpiece= '
	else if @action = 6
	begin
		select ' + @columnlist + ' from ' + @qualified_name + ' t where 1=2

		if @@error <> 0 set @retcode= 1
	end
	'

	insert into @cmdtable (phase, cmdtext) values (11, @cmdpiece)

	-- Procedure tail.
	set @cmdpiece= '
	return @retcode
'

	insert into @cmdtable (phase, cmdtext) values (12, @cmdpiece)

	-- Now we select out the command text pieces in proper order so that our caller,
	-- xp_execresultset, will execute the command that creates the stored procedure.
	select cmdtext from @cmdtable order by phase, step

	drop table #columnvaluequery

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MScreatelightweightmultipurposeproc] TO [public] AS [dbo]
GO
