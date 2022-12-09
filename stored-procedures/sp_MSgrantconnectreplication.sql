SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgrantconnectreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgrantconnectreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgrantconnectreplication]
	@user_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @command nvarchar(400)
    select @command = N'grant connect replication to ' + quotename(@user_name)
    exec(@command)
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSgrantconnectreplication] TO [public] AS [dbo]
GO
