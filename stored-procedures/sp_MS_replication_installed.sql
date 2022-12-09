SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MS_replication_installed]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MS_replication_installed] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MS_replication_installed]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @isinstalled int
    select @isinstalled = 0
    declare @retcode int
    
    EXECUTE @retcode = master.dbo.xp_instance_regread 'HKEY_LOCAL_MACHINE', 
        'SOFTWARE\Microsoft\MSSQLServer\Replication',
        'IsInstalled',
        @param = @isinstalled OUTPUT

    IF ( @retcode <> 0 ) or ( @@ERROR <> 0 ) 
    begin
        raiserror (21028, 16, -1)
        return (0)
    end
    
    if (@isinstalled is null or @isinstalled = 0)
    begin
        raiserror (21028, 16, -1)
        return (0)
    end

    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MS_replication_installed] TO [public] AS [dbo]
GO
