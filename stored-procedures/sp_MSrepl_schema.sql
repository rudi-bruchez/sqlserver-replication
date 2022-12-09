SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_schema]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_schema] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_schema]
	@pubname [sysname],
	@artid [int],
	@qual_source_object [nvarchar](517),
	@column [sysname],
	@operation [int],
	@typetext [nvarchar](3000),
	@schema_change_script [nvarchar](4000)
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    declare @pubid int
    declare @objid int
    declare @schema_option binary(8)
    declare @auto_gen int
    declare @cmd_type int
    declare @ins_cmd nvarchar(510)
    declare @del_cmd nvarchar(510)
    declare @upd_cmd nvarchar(510)
    declare @repub_command nvarchar(4000)
    declare @nopub_command nvarchar(4000)
    declare @prefix nvarchar(32)
    declare @post_cmd nvarchar(4000)
    declare @qual_column nvarchar(362) 
    declare @use_script bit
    declare @allow_dts bit
    
    set nocount on
    select @retcode = 0
    select @auto_gen = 2 -- auto generate custom procs
    select @cmd_type = 11 -- ALter Table statement
    select @qual_column = QUOTENAME(@column)
    select @objid = object_id(@qual_source_object)

    /*
    ** Security Check
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    if (@schema_change_script is not NULL) and (len(@schema_change_script) > 0)
        select @use_script = 1
    else
        select @use_script = 0
    
    
    select @pubid = a.pubid, @schema_option = schema_option, @ins_cmd = ins_cmd, @del_cmd = del_cmd, @upd_cmd = upd_cmd, @allow_dts = allow_dts 
        from sysarticles a join syspublications p on a.pubid = p.pubid where artid = @artid
    
    if (@allow_dts = 1)
        goto SCRIPTONLY

    if(@operation = 0)
    begin
        select @repub_command = N'exec sp_repladdcolumn @source_object=N''' + replace(@qual_source_object, N'''', N'''''') + N''',@column=N''' + replace(@column  , N'''', N'''''')
                        + N''',@typetext=N''' + replace(@typetext, N'''', N'''''') + N''' '
        select @nopub_command = N'else alter table ' + @qual_source_object + N' add ' + @qual_column + N' ' + @typetext + N' ' 
        select @prefix = N'if not exists '
    end
    else
    begin
        select @repub_command = N'exec sp_repldropcolumn @source_object=N''' + replace(@qual_source_object, N'''', N'''''') + N''',@column=N''' + replace(@column  , N'''', N'''''')  + N''' '
        select @nopub_command = N'else alter table ' + @qual_source_object + N' drop column ' + @qual_column + N' '
        select @prefix = N'if exists '
    end
    if (@use_script = 1)--Need to pass the script file along if sub is republished.
        select @repub_command = @repub_command  + N',@schema_change_script=N''' + @schema_change_script + N''' '
    select @post_cmd = @prefix + N'(select * from dbo.syscolumns where name=''' + replace(@column  , N'''', N'''''') + ''' and id = object_id('''+ replace(quotename(PARSENAME(@qual_source_object, 1)), N'''', N'''''')  + ''')) begin '
    exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @cmd_type, @post_cmd 
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    select @post_cmd = N'if exists (select * from dbo.sysobjects where name=''syspublications'') if exists (select * from sysarticles where objid=object_id('''+ replace(quotename(PARSENAME(@qual_source_object, 1)), N'''', N'''''')  + ''')) and @@microsoftversion >= 0x07320000 '
    exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @cmd_type, @post_cmd 
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @cmd_type, @repub_command
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @cmd_type, @nopub_command
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @cmd_type, @nopub_command
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    exec @retcode = sys.sp_replpostcmd 0, @pubid, @artid, @cmd_type, N' end '
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    
    if ((convert(int, @schema_option) & @auto_gen) > 0)-- No script, but custom procs were auto-generated
    begin
        if (UPPER(LEFT(LTRIM(@ins_cmd), 4) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('CALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@ins_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('SCALL' collate SQL_Latin1_General_CP1_CS_AS))
        begin
            exec @retcode = sys.sp_MSpost_auto_proc @pubid=@pubid, @artid=@artid, @procmapid=1 
            if(@retcode <> 0) or (@@error <> 0)
                return 1
        end
        if(UPPER(LEFT(LTRIM(@del_cmd), 4) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('CALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@del_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('XCALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@del_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('VCALL' collate SQL_Latin1_General_CP1_CS_AS))
        begin
            exec @retcode = sys.sp_MSpost_auto_proc @pubid=@pubid, @artid=@artid, @procmapid=2 
            if(@retcode <> 0) or (@@error <> 0)
                return 1
        end
        if(UPPER(LEFT(LTRIM(@upd_cmd), 4) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('CALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@upd_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('MCALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@upd_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('XCALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@upd_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('VCALL' collate SQL_Latin1_General_CP1_CS_AS))
        	or (UPPER(LEFT(LTRIM(@upd_cmd), 5) collate SQL_Latin1_General_CP1_CS_AS) = UPPER('SCALL' collate SQL_Latin1_General_CP1_CS_AS))
        begin
            exec @retcode = sys.sp_MSpost_auto_proc @pubid=@pubid, @artid=@artid, @procmapid=3 
            if(@retcode <> 0) or (@@error <> 0)
                return 1
        end
    end
SCRIPTONLY:

    if (@use_script = 1)
    begin
        exec @retcode = sys.sp_addscriptexec @publication = @pubname, @scriptfile = @schema_change_script
        if @retcode<>0 or @@ERROR<>0
            return 1
    end 
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_schema] TO [public] AS [dbo]
GO
