SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatelightweightupdateproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatelightweightupdateproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatelightweightupdateproc]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @argname            nvarchar(10)
	declare @tablenick			int
	declare @destination_object	sysname
	declare @destination_owner	sysname
	declare @qualified_name     nvarchar(270)
	declare @cmdpiece 			nvarchar(4000)
	declare @postfix			nchar(32)
	declare @id                 int
	declare @colid 				int
	declare @previouscolid		int
	declare @columnordinal		smallint
	declare @colname 			nvarchar(200)
	declare @typename			sysname
	declare @len				smallint
	declare @prec				int
	declare @scale				int
	declare @isrowguidcol		tinyint
	declare @comma				nvarchar(2)
	declare @retcode            int
	declare @maintainsmetadata	bit
	declare @coltracked			bit
	declare @enumtype_str		nvarchar(100)
	declare @cmdtable			table (phase int not null, 
									   step int identity not null, 
									   cmdtext nvarchar(4000) collate database_default null)

	-- Security check
	exec @retcode= sys.sp_MSreplcheck_subscribe
	if @@error <> 0 or @retcode <> 0 return (1)

	select @tablenick= nickname, 
		   @destination_object= destination_object, 
		   @postfix= procname_postfix, 
		   @destination_owner= destination_owner,
		   @coltracked= column_tracking
		from dbo.sysmergearticles 
		where pubid = @pubid and artid = @artid

	if 1=@coltracked
	begin
		set @enumtype_str= '@COLUMNS_ENUMERATED_ChangedOnly'
	end
	else
	begin
		set @enumtype_str= '@COLUMNS_ENUMERATED_AllOnOtherReason'
	end

	set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)

	if @destination_owner is null or @destination_owner = ''
		select @qualified_name = quotename(@destination_object)
	else
		select @qualified_name = quotename(@destination_owner) + '.' + quotename(@destination_object)

	-- Phase 0: Create procedure and fixed part of argument list.
	set @cmdpiece= 'create procedure dbo.' + quotename('MSmerge_lws_sp_upd_'  + @postfix) + '
	@rowguid	uniqueidentifier,
	@setnullbm	varbinary(128)'

	if 1 = @maintainsmetadata
	begin
		set @cmdpiece= @cmdpiece + ',
		@rowvector		varbinary(11)'
	end

	insert into @cmdtable (phase, cmdtext) values (0, @cmdpiece)

	-- Phase 1: Column arguments list. This will be done later.

	-- Phase 2: Open procedure body.
	set @cmdpiece='
	as 
	set nocount on

	-- Security check
	if (is_member(''db_owner'') <> 1)
	begin
		raiserror(15247,-1,-1)
		return (1)
	end

	declare @tablenick	int
	set @tablenick= ' + cast(@tablenick as nvarchar(20)) + '
	'

	insert into @cmdtable (phase, cmdtext) values (2, @cmdpiece)

	-- Phase 3: Add all code up to column list in update statement.
	if 1=@maintainsmetadata
	begin
		set @cmdpiece= 
		'
		declare @errcode	int
		declare @METADATA_TYPE_UpsertLightweightProcessed tinyint'

		if 1=@coltracked
		begin
			set @cmdpiece=@cmdpiece + '
			declare @COLUMNS_ENUMERATED_ChangedOnly tinyint

			set @COLUMNS_ENUMERATED_ChangedOnly= 0'
		end
		else
		begin
			set @cmdpiece=@cmdpiece + '
			declare @COLUMNS_ENUMERATED_AllOnOtherReason tinyint

			set @COLUMNS_ENUMERATED_AllOnOtherReason= 2'
		end

		set @cmdpiece=@cmdpiece + '
		set @METADATA_TYPE_UpsertLightweightProcessed= 11

		begin tran
		save tran tran_lws_updproc
		
		update dbo.MSmerge_rowtrack
			set	
				changetype= @METADATA_TYPE_UpsertLightweightProcessed, 
				rowvector= @rowvector, 
				changedcolumns= null,
				columns_enumeration= ' + @enumtype_str + ',
				changed= sys.fn_MSdayasnumber(getdate()),
				sync_cookie= null
			where tablenick = @tablenick and rowguid = @rowguid

		if @@rowcount = 0
		begin
			insert into dbo.MSmerge_rowtrack
			(
				tablenick, 
				rowguid, 
				changetype, 
				rowvector, 
				changedcolumns, 
				columns_enumeration, 
				changed, 
				sync_cookie
			)
			values
			(
				@tablenick, 
				@rowguid, 
				@METADATA_TYPE_UpsertLightweightProcessed, 
				@rowvector, 
				null, 
				' + @enumtype_str + ', 
				sys.fn_MSdayasnumber(getdate()), 
				null
			)

			if @@rowcount <> 1
			begin
				set @errcode= 3
				goto Failure
			end
		end

		update ' + @qualified_name + '
			set'
	end -- 1=@maintainsmetadata
	else
	begin
		set @cmdpiece= 
		'
		declare @errcode	int

		update ' + @qualified_name + '
			set'
	end
	
	insert into @cmdtable (phase, cmdtext) values (3, @cmdpiece)

	-- Phase 4: Add sequence of <column=value> in update statement. Will be done later

	-- Phase 5: Close update statement, and complete the stored proc.
	set @cmdpiece= '
		where rowguidcol = @rowguid
		
	if (@@rowcount <> 1)
	begin
		set @errcode= 3
		goto Failure
	end
	else
	begin
		set @errcode= 1
		delete from dbo.MSmerge_metadataaction_request
			where tablenick=@tablenick and rowguid=@rowguid
				
		goto Done
	end'

	if 1 = @maintainsmetadata
	begin
		set @cmdpiece= @cmdpiece + '
		Failure:
			rollback tran tran_lws_updproc

		Done:
			commit tran
			return @errcode
			'
	end
	else
	begin
		set @cmdpiece= @cmdpiece + '
		Failure:
		Done:
			return @errcode
			'
	end

	insert into @cmdtable (phase, cmdtext) values (5, @cmdpiece)

	-- Now we loop over the columns to complete the command.
	-- We omit computed, identity, and timestamp columns.

	select @id= object_id(@qualified_name)
	if @id is null return (1)
	
	set @columnordinal= 0
	set @previouscolid= -1
	set @comma= ''
	while (1=1)
	begin
		set @columnordinal= @columnordinal + 1
		
		set @colid= (select min(column_id) from sys.columns 
						where object_id = @id and 
							  column_id > @previouscolid and
							  is_computed = 0 and
							  is_identity = 0 and	-- Identity column
							  system_type_id <> type_id('timestamp'))

		if @colid is null
			break

		set @previouscolid= @colid

		select 
			@colname= quotename(name), 
			@typename= type_name(system_type_id),
		    @len= max_length,
		    @prec= precision, 
		    @scale= scale,
			@isrowguidcol= is_rowguidcol
		    from sys.columns 
		    where object_id = @id and column_id = @colid

		if @typename='nvarchar' or @typename='nchar' -- a unit of nchar takes 2 bytes
			select @len= @len/2

	    exec @retcode= sys.sp_MSmaptype @typename out, @len, @prec, @scale
	    if @@error<>0 or @retcode <>0 return (1)

		-- Phase 1: Add column to procedure arguments list.
		--			The list also contains the rowguidcol.
	    select @argname= '@p' + convert(nvarchar, @columnordinal)
	    set @cmdpiece= ',
	    ' + @argname + ' ' + @typename + '=null'

	    insert into @cmdtable (phase, cmdtext) values (1, @cmdpiece)

		-- Phase 4: Add sequence of <column=value> in update statement.
		--			Unlike in the argument list of phase 1, we now omit the rowguidcol.
		if @isrowguidcol = 1
			continue

		set @cmdpiece= @comma + '
			' + @colname + '= case' + '
				when ' + @argname + ' is not null then ' + @argname + '
				when @setnullbm =0x00 then ' + @colname + '
				when 1 = sys.fn_MStestbit(@setnullbm, ' + convert(nvarchar, @columnordinal) + ') then null
				else ' + @colname + '
			end'

	    insert into @cmdtable (phase, cmdtext) values (4, @cmdpiece)

	    set @comma= ', '
	end

	-- Now we select out the command text pieces in proper order so that our caller,
	-- xp_execresultset, will execute the command that creates the stored procedure.
	select cmdtext from @cmdtable order by phase, step

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MScreatelightweightupdateproc] TO [public] AS [dbo]
GO
