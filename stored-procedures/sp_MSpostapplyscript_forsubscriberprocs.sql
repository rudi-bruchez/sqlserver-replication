SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpostapplyscript_forsubscriberprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpostapplyscript_forsubscriberprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpostapplyscript_forsubscriberprocs]
	@procsuffix [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode        smallint
    declare @procname       nvarchar(400)
    declare @ownername      nvarchar(140)
    declare @destowner      nvarchar(140)
    declare @ins_procname   nvarchar(258)
    declare @ins_batch_procname nvarchar(258)
    declare @upd_procname   nvarchar(258)
    declare @upd_batch_procname nvarchar(258)
    declare @sel_procname nvarchar(258)
    declare @sel_metadata_procname nvarchar(258)
    declare @del_procname nvarchar(258)
    declare @conflict_proc nvarchar(258)

    set nocount on
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    select @ins_procname = quotename('MSmerge_ins_sp_' + @procsuffix)
    select @ins_batch_procname = quotename('MSmerge_ins_sp_' + @procsuffix + '_batch')
    select @upd_procname = quotename('MSmerge_upd_sp_' + @procsuffix)
    select @upd_batch_procname = quotename('MSmerge_upd_sp_' + @procsuffix + '_batch')
    select @del_procname = quotename('MSmerge_del_sp_' + @procsuffix)
    select @sel_procname = quotename('MSmerge_sel_sp_' + @procsuffix)
    select @sel_metadata_procname = quotename('MSmerge_sel_sp_' + @procsuffix + '_metadata')
    select @conflict_proc = quotename('MSmerge_cft_sp_' + @procsuffix)

	select @procname = @ins_procname
	if object_id(@ins_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end
	    
    select @procname = @ins_batch_procname
	if object_id(@ins_batch_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @upd_procname
	if object_id(@upd_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @upd_batch_procname
	if object_id(@upd_batch_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @del_procname
	if object_id(@del_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @sel_procname
	if object_id(@sel_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @sel_metadata_procname
	if object_id(@sel_metadata_procname ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end

    select @procname = @conflict_proc
	if object_id(@conflict_proc ,'P') is not NULL
	begin
	    exec sys.sp_MS_marksystemobject @procname	    
	    exec ('grant exec on ' + @procname + ' to public')
    end
end
GO
GRANT EXECUTE ON [sys].[sp_MSpostapplyscript_forsubscriberprocs] TO [public] AS [dbo]
GO
