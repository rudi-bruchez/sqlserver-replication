SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_tempgenhistorytable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_tempgenhistorytable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_tempgenhistorytable]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @qual_temp_genhistory_table sysname
    declare @guidstr varchar(100)
    declare @cmd nvarchar(4000)
    declare @objid sysname

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    select @guidstr = sys.fn_MSguidtostr(@pubid)

    select @qual_temp_genhistory_table = 'dbo.MSmerge_genhistory_' + LOWER(@guidstr)

    -- check for system object is done while creating the table, not necessary here.
    -- passive drop, don't worry about the failure
    exec ('if object_id(''' + @qual_temp_genhistory_table + ''') is not null  drop table ' + @qual_temp_genhistory_table)    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_tempgenhistorytable] TO [public] AS [dbo]
GO
