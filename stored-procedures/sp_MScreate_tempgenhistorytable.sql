SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreate_tempgenhistorytable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreate_tempgenhistorytable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreate_tempgenhistorytable]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @temp_genhistory_table sysname
    declare @qual_temp_genhistory_table sysname
    declare @guidstr varchar(100)
    declare @cmd nvarchar(4000)
    declare @objid sysname
    declare @is_system_object bit

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    select @guidstr = sys.fn_MSguidtostr(@pubid)
    select @temp_genhistory_table = 'MSmerge_genhistory_' + LOWER(@guidstr)
    select @qual_temp_genhistory_table = 'dbo.' + @temp_genhistory_table

    select @objid = object_id, @is_system_object = is_ms_shipped from sys.objects where name = @temp_genhistory_table

    if (@objid is null)
    begin
        select @cmd = 'select * into ' + @qual_temp_genhistory_table + ' from dbo.MSmerge_genhistory where 1=2'

        exec @retcode = sys.sp_executesql @cmd
        if @@error <> 0 or @retcode <> 0
            goto Failure

        exec @retcode = sys.sp_MS_marksystemobject @temp_genhistory_table
        if @@error<>0 or @retcode<>0
            goto Failure        
    end
    else if (@is_system_object = 0)
    begin
        -- temp_genhistory table is probably a user table.
        raiserror(20008, 16, -1)
        return 1
    end   
    return (0)
    
Failure:  
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MScreate_tempgenhistorytable] TO [public] AS [dbo]
GO
