SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatelightweightinsertproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatelightweightinsertproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatelightweightinsertproc]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @argname						nvarchar(10)
	declare @id								int
	declare @tablenick						int
	declare @destination_object				sysname
	declare @destination_owner				sysname
	declare @qualified_name					nvarchar(270)
	declare @colid							int
	declare @previouscolid					int
	declare @colname						nvarchar(200)
	declare @typename						nvarchar(258)
	declare @len							smallint
	declare @prec							int
	declare @scale							int
	declare @isidentitycolumn               bit
	declare @is_identitynotforreplication	bit
	declare @columnordinal					smallint
	declare @retcode						int
	declare @comma							nvarchar(2)
	declare @cmdpiece						nvarchar(4000)
	declare @postfix						nchar(32)
	declare @maintainsmetadata				bit
	declare @coltracked						bit
	declare @enumtype_str					nvarchar(100)
	declare @cmdtable						table (phase int not null, 
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

	if @destination_owner is null or @destination_owner=''
		select @qualified_name = quotename(@destination_object)
	else
		select @qualified_name = quotename(@destination_owner) + '.' + quotename(@destination_object)

	-- Phase 0: Create procedure and fixed part of argument list.
	if 1 = @maintainsmetadata
	begin
		set @cmdpiece=
		'create procedure dbo.' + quotename('MSmerge_lws_sp_ins_'	+ @postfix) + '
			@rowguid uniqueidentifier,
			@rowvector varbinary(11)'
	end
	else
	begin
		set @cmdpiece=
		'create procedure dbo.' + quotename('MSmerge_lws_sp_ins_'	+ @postfix) + '
			@rowguid uniqueidentifier'
	end

	insert into @cmdtable (phase, cmdtext) values (0, @cmdpiece)

	-- Phase 1: Column arguments list. This will be done later.

	-- Phase 2: Open procedure body.
	set @cmdpiece='
	as 
	declare @errcode	int
	set nocount on'
	insert into @cmdtable (phase, cmdtext) values (2, @cmdpiece)


    -- phase 3,4 and 5 are optional. Used only for downloadonly
    -- articles to call update proc before attempting insert.
    if 1 <> @maintainsmetadata
    begin
        --phase 3 : fixed part of the call to update proc.
        set @cmdpiece = '
    -- Call the update proc first because this is a download only article
    set @errcode= 0
    exec @errcode = dbo.' + quotename('MSmerge_lws_sp_upd_'	+ @postfix) + ' 
	@rowguid = @rowguid,
	@setnullbm = 0x00 '
        insert into @cmdtable (phase, cmdtext) values (3, @cmdpiece)
        -- phase 4 is rest of argument list; goes in during loop over columns

        -- phase 5 is the reset of the fixed part of the call to
        -- update proc
        set @cmdpiece = '
        if @errcode = 1
		return(1)'
        insert into @cmdtable (phase, cmdtext) values (5, @cmdpiece)
    end



	
	-- phase 6
	set @cmdpiece='-- Security check
	if (is_member(''db_owner'') <> 1)
	begin
		raiserror(15247,-1,-1)
		return (3)
	end

	declare @tablenick	int
	set @tablenick= ' + cast(@tablenick as nvarchar(20)) + '
	'

	insert into @cmdtable (phase, cmdtext) values (6, @cmdpiece)

	-- Phase 7: Enable identity_insert, if needed. This is done later.
	
	-- Phase 8: Add all code up to column list in insert statement.
	if 1=@maintainsmetadata
	begin
		set @cmdpiece= 
		'
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
		save tran tran_lws_insproc

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

		insert into ' + @qualified_name + '
			('
	end -- 1=@maintainsmetadata
	else
	begin
		set @cmdpiece= 
		'
		insert into ' + @qualified_name + '
		('
	end
	
	insert into @cmdtable (phase, cmdtext) values (8, @cmdpiece)

	-- Phase 9: Column name list in insert statement. Will be done later.

	-- Phase 10: "values" keyword in insert statement
	set @cmdpiece= ')
		values
		('

	insert into @cmdtable (phase, cmdtext) values (10, @cmdpiece)

	-- Phase 11: Column value list in insert statement. Will be done later.

	-- Phase 12: Close insert statement, and prepare for completion of the stored proc.
	set @cmdpiece= ')
	if @@rowcount <> 1
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
			rollback tran tran_lws_insproc

		Done:
			commit tran
			'
	end
	else
	begin
		set @cmdpiece= @cmdpiece + '
		Failure:
		Done:
			'
	end

	insert into @cmdtable (phase, cmdtext) values (12, @cmdpiece)

	-- Phase 13: Disable identity_insert, if previously enabled. This is done later.

	-- Phase 14: Return.
	set @cmdpiece= '
	
	return(@errcode)
	'

	insert into @cmdtable (phase, cmdtext) values (14, @cmdpiece)

	-- Now we loop over the columns to complete the command.
	-- We omit computed and timestamp columns.

	select @id= object_id(@qualified_name)
	if @id is null return (1)
	
	set @columnordinal= 0
	set @previouscolid= -1
	while (1=1)
	begin
		set @columnordinal= @columnordinal + 1
		
		set @colid= (select min(column_id) from sys.columns 
						where object_id = @id and 
							  column_id > @previouscolid and
							  is_computed = 0 and
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
			@isidentitycolumn= is_identity, 
			@is_identitynotforreplication = convert(bit, isnull(columnproperty(@id, name, 'IsIdNotForRepl'), 0)) 
			from sys.columns 
			where object_id = @id and column_id = @colid

		if @typename='nvarchar' or @typename='nchar' -- a unit of nchar takes 2 bytes
			select @len= @len/2

		exec @retcode= sys.sp_MSmaptype @typename out, @len, @prec, @scale
		if @@error<>0 or @retcode <>0 return (1)

		-- Phase 1: Add column to procedure arguments list. 
		select @argname= '@p' + convert(nvarchar, @columnordinal)
		set @cmdpiece= ',
		' + @argname + ' ' + @typename
		insert into @cmdtable (phase, cmdtext) values (1, @cmdpiece)

		-- Phase 4: argument list for call to update proc in downloadonly case
		if 1 <> @maintainsmetadata
		begin
    		set @cmdpiece= ',
    		' + @argname + ' = ' + @argname
    		insert into @cmdtable (phase, cmdtext) values (4, @cmdpiece)
  		end

		if @columnordinal = 1
			set @comma= ''
		else
			set @comma= ', '

		-- Phase 9: Add column names to insert statement. 
		set @cmdpiece= @comma + @colname
		insert into @cmdtable (phase, cmdtext) values (9, @cmdpiece)
		
		-- Phase 11: Add respective parameters to insert statement.
		set @cmdpiece= @comma + @argname
		insert into @cmdtable (phase, cmdtext) values (11, @cmdpiece)

		-- is this an identity column without 'not for replication' marking?
		if (@isidentitycolumn = 1) and (@is_identitynotforreplication = 0)
		begin
			-- Phase 7: Enable identity_insert.
			set @cmdpiece = '	set identity_insert ' + @qualified_name + ' on'
			insert into @cmdtable (phase, cmdtext) values (7, @cmdpiece)

			-- Phase 9: Disable identity_insert.
			set @cmdpiece = '	set identity_insert ' + @qualified_name + ' off'
			insert into @cmdtable (phase, cmdtext) values (13, @cmdpiece)
		end
	end

	-- Now we select out the command text pieces in proper order so that our caller,
	-- xp_execresultset, will execute the command that creates the stored procedure.
	select cmdtext from @cmdtable order by phase, step

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MScreatelightweightinsertproc] TO [public] AS [dbo]
GO
