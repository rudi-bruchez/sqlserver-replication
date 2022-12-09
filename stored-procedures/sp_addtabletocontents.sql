SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addtabletocontents]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addtabletocontents] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addtabletocontents]
	@table_name [sysname],
	@owner_name [sysname],
	@filter_clause [nvarchar](4000)
WITH EXECUTE AS CALLER
AS
begin
	declare @qualified_table_name nvarchar(540)
	declare @tablenick int
	declare @tablenickstr nvarchar(12)
	declare @replnick binary(6)
	declare @lineage varbinary(311)
	declare @colv varbinary(2953)
	declare @coltrack int
	declare @objid int
	declare @retcode int
	declare @gen bigint
	declare @marker uniqueidentifier
	declare @command nvarchar(max)
	declare @artid uniqueidentifier
	
	set nocount on

	-- Security Checking 
	-- sysadmin or db_owner have access

	if is_srvrolemember('sysadmin') <> 1 and 
			is_member('db_owner') <> 1
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	execute @retcode = sys.sp_MSgetreplnick @replnick = @replnick output
	if (@@error <> 0) or @retcode <> 0 or @replnick IS NULL 
		begin
		RAISERROR (14055, 11, -1)
		RETURN(1)
		end					

	if @owner_name is NULL
	begin
		select @owner_name = SCHEMA_NAME(schema_id) from sys.objects where name = @table_name
	end
	set @qualified_table_name = QUOTENAME(@owner_name) + '.' + QUOTENAME(@table_name)
	
	set @objid = object_id(@qualified_table_name)
	if @objid is NULL return (1)
	select top 1 @tablenick = nickname, @coltrack = column_tracking, @artid = artid
	from dbo.sysmergearticles where objid = @objid
	order by column_tracking desc
	
	if @coltrack = 1
		set @colv = 0xFF
	else
		set @colv = NULL
	set @lineage = { fn UPDATELINEAGE(0x0, @replnick, 1) }

	set @tablenickstr = convert(nchar, @tablenick)
	select @marker = newid()
	
	if @filter_clause is null
		select @filter_clause = N''
		
	begin tran
	save tran addtabletocontents

	if @filter_clause is null or @filter_clause = N''
	begin
		select @command = 'insert into dbo.MSmerge_contents (tablenick, rowguid, generation, partchangegen, lineage, colv1, marker)
				select @tablenick, rowguidcol, @gen, (-@gen), @lineage, @colv, @marker
				from ' + @qualified_table_name + ' 
				where rowguidcol not in (select rowguid from dbo.MSmerge_contents where tablenick = @tablenick)'
	end
	else
	begin
		-- first run a simplified command (w/o variables) through sp_repl_validate_parameter to avoid SQL injection risk
		select @command = 'insert into dbo.MSmerge_contents (rowguid)
				select rowguidcol
				from ' + @qualified_table_name + ' 
				where (' + @filter_clause + ')
				and rowguidcol not in (select rowguid from dbo.MSmerge_contents)'
		exec @retcode = sys.sp_repl_validate_parameter @str = @command
		if (@@error <> 0) or @retcode <> 0
			goto Error

		select @command = 'insert into dbo.MSmerge_contents (tablenick, rowguid, generation, partchangegen, lineage, colv1, marker)
				select @tablenick, rowguidcol, @gen, (-@gen), @lineage, @colv, @marker
				from ' + @qualified_table_name + ' 
				where (' + @filter_clause + ')
				and rowguidcol not in (select rowguid from dbo.MSmerge_contents where tablenick = @tablenick)'
	end
	
	exec @retcode = sys.sp_MSmerge_getgencur @tablenick = @tablenick, @changecount = 0, @gen_cur = @gen output
	if @@error <> 0 or @retcode <> 0
		goto Error
	
	exec @retcode = sys.sp_executesql @command, 
						N'@tablenick int, @gen bigint, @lineage varbinary(311), @colv varbinary(2953), @marker uniqueidentifier',
						@tablenick = @tablenick, @gen = @gen, @lineage = @lineage, @colv = @colv, @marker = @marker
	if @@error <> 0 or @retcode <> 0
		goto Error
		
	exec @retcode = sys.sp_MSevaluate_change_membership_for_row @tablenick = @tablenick, @marker = @marker
	if @@error <> 0 or @retcode <> 0
		goto Error
		
	exec @retcode = sys.sp_MSevaluate_logicalrecordparent_allcontentsrows @artid = @artid
	if @@error <> 0 or @retcode <> 0
		goto Error
		
	commit tran
	
	return 0

Error:

	rollback tran addtabletocontents
	commit tran
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_addtabletocontents] TO [public] AS [dbo]
GO
