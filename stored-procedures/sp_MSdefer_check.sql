SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdefer_check]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdefer_check] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdefer_check]
	@objname [sysname],
	@objowner [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @cnstname sysname
    declare @cnstid int
    declare @objid int
    declare @enable_cmd nvarchar(4000)
    declare @disable_cmd nvarchar(4000)
    declare @quotedproc nvarchar(240)
    declare @dest nvarchar(514)
    declare @dbname sysname
    declare @proc_exists bit

    if(@objowner is not null)
        select @dest = quotename(@objowner) + N'.' + quotename(@objname)
    else
        select @dest = quotename(@objname)

    declare @retcode int
    IF @objname IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@objname', 'sp_MSdefer_check')
        RETURN (1)
    END

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
            return (1)

    select @objid = object_id(@dest)
    select @enable_cmd = N'sp_MSenable_' + convert(varchar(64), @objid)
    if exists(select name from sys.objects where name = @enable_cmd and ObjectProperty(object_id, 'IsProcedure') = 1)
        select @proc_exists = 1
    else
        select @proc_exists = 0

    select @quotedproc = quotename(@enable_cmd)
    select @enable_cmd = N'create procedure ' + @quotedproc + N' as '
    create table #proccmd (c1 int identity, c2 nvarchar(3000) collate database_default)
    insert #proccmd (c2) values (@enable_cmd)
    
    declare ms_crs_cnst cursor local static for
    select name, object_id 
    	from sys.objects 
    	where parent_object_id = @objid 
    		and OBJECTPROPERTY(object_id, 'CnstIsDisabled') = 0 
    		and OBJECTPROPERTY(object_id, 'CnstIsNotRepl') = 0
    		and (OBJECTPROPERTY(object_id, 'IsCheckCnst') = 1 
    			or OBJECTPROPERTY(object_id, 'IsForeignKey') = 1)
    union
    select name, object_id
    	from sys.triggers
    	where parent_id = @objid
        	and OBJECTPROPERTY(object_id, 'IsTrigger') = 1 
        	and OBJECTPROPERTY(object_id, 'ExecIsTriggerNotForRepl') = 0 
        	and OBJECTPROPERTY(object_id, 'ExecIsTriggerDisabled') = 0
    for read only

    open ms_crs_cnst
    fetch ms_crs_cnst into @cnstname, @cnstid
    while @@fetch_status >= 0
    begin
        if(ObjectProperty(@cnstid, 'IsTrigger') = 1)
        begin
            select @disable_cmd = N'alter table ' + @dest + N' disable trigger ' + quotename(@cnstname)
            select @enable_cmd = N'alter table ' + @dest + N' enable trigger '+quotename(@cnstname)
        end
        else
        begin
            select @disable_cmd = N'alter table ' + @dest + N' nocheck constraint ' + quotename(@cnstname)
            select @enable_cmd = N'alter table ' + @dest + N' check constraint ' + quotename(@cnstname)
        end
        insert #proccmd (c2) values (@enable_cmd)

        execute(@disable_cmd)
        fetch ms_crs_cnst into @cnstname, @cnstid
    end     --of major loop
    deallocate ms_crs_cnst
    if(@proc_exists = 1) -- don't try to recreate the proc
    begin 
        select N'exec ' + @quotedproc
        drop table #proccmd
        return 0
    end

    select @enable_cmd = N'drop proc ' + @quotedproc
    insert #proccmd (c2) values (@enable_cmd)
    select @enable_cmd = N'select c2 from #proccmd order by c1'
    select @dbname = db_name()
    exec @retcode = sys.xp_execresultset @enable_cmd, @dbname
    if @@error <> 0 or @retcode <> 0 or @quotedproc is NULL
    begin
        declare @cmd_param nvarchar(4000)
        if (@objowner is null)
            select @cmd_param = N' @objname = N''' + @objname + N''''
        else
            select @cmd_param = N' @objname = N''' + @objname + N''', @objowner = N''' + @objowner + N''''
        select N'exec sp_MSreenable_check ' + @cmd_param
    end
    else
        select N'exec ' + @quotedproc
    drop table #proccmd
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSdefer_check] TO [public] AS [dbo]
GO
