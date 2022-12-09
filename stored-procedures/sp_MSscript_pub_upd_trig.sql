SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscript_pub_upd_trig]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscript_pub_upd_trig] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscript_pub_upd_trig]
	@publication [sysname],
	@article [sysname],
	@procname [sysname],
	@alter [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @cmd       nvarchar(4000)
    declare @qualname  nvarchar(517)
    declare @objid     int
    declare @artid     int
                ,@retcode int

    set nocount on
    --
    -- security check -- dbo+ to script create or alter
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end

    -- Create temp table
    create table #proctext ( c1 int identity NOT NULL, procedure_text nvarchar(4000) collate database_default null)

    -- Retrieve underlying table name and replicated columns
    select @objid = objid, @artid = a.artid from sysarticles a join syspublications p on  a.pubid = p.pubid
        where a.name = @article and
              p.name = @publication 

    exec sys.sp_MSget_qualified_name @objid, @qualname OUTPUT

    -- Trigger should be invoked for repl processes as well.
    select @cmd = case @alter when 0 then N'create' else N'alter' end + ' trigger ' + QUOTENAME(@procname) + N' on ' + @qualname + N' '

    select @cmd = @cmd + N'for update not for replication as ' 

    exec sys.sp_MSflush_command @cmd output, 1

    insert into #proctext(procedure_text) values(N'
')
    -- declare common local variables
    insert into #proctext(procedure_text) values 
        (N'declare @rc int
')
    insert into #proctext(procedure_text) values(N'select @rc = @@ROWCOUNT 

')
        
    -- Optimization. Return immediately if no row changed
    -- This must be at the beginning of the trigger to @@rowcount be overwritten.
    insert into #proctext(procedure_text) values(N'if @rc = 0 return 
')
    insert into #proctext(procedure_text) values(N'if update (msrepl_tran_version) return 
')

    -- update the version column of all the updated rows all at once.
    select @cmd = N'update ' + @qualname + N' set msrepl_tran_version = newid() from ' +
        @qualname + ', inserted '
    exec sys.sp_MSflush_command @cmd output, 1
    insert into #proctext(procedure_text) values(N'
')
    exec sys.sp_MSscript_where_clause @objid, @artid, 'version pk', null, 4

    insert into #proctext(procedure_text) values(N'
')
    -- send fragments to client
    select procedure_text from #proctext order by c1 asc
end
GO
GRANT EXECUTE ON [sys].[sp_MSscript_pub_upd_trig] TO [public] AS [dbo]
GO
