SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdroptemptable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdroptemptable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdroptemptable]
	@tname [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @quotedtname nvarchar(260)
    select @quotedtname = quotename(@tname)

	declare @command nvarchar(1000)
	select @command = 'if OBJECT_ID(''tempdb..' + replace(@quotedtname, '''', '''''') + ''') is not NULL drop table ' + replace(@quotedtname, '''', '''''')
    
    exec (@command)

    if @@ERROR <> 0 
        return(1)
    
    return (0)  
end
GO
GRANT EXECUTE ON [sys].[sp_MSdroptemptable] TO [public] AS [dbo]
GO
