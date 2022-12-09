SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreleaseSlotLock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreleaseSlotLock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreleaseSlotLock]
	@process_name [sysname],
	@DbPrincipal [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int

-- Security Checking 
-- sysadmin or db_owner or replication agent have access

exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
if (@retcode <> 0) or (@@error <> 0)
begin
        RAISERROR (14126, 11, -1)
       return 1
end

exec @retcode=sys.sp_releaseapplock @process_name,@LockOwner=N'Session',@DbPrincipal=@DbPrincipal
IF (@retcode <> 0)
    BEGIN
        RAISERROR(21415, 16, -1)
        return (1)
    END
return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSreleaseSlotLock] TO [public] AS [dbo]
GO
