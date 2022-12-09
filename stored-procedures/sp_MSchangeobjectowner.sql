SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchangeobjectowner]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchangeobjectowner] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchangeobjectowner]
	@tablename [sysname],
	@dest_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @uid         smallint
    declare @retcode    int
    
    -- Security check
    exec @retcode= sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(15247, 11, -1)
        return (1)
    end

    select @uid=schema_id from sys.objects where name=@tablename

    --do not bother to call sp_changeobjectowner the object is owned by the @dest_owner itself
    if SCHEMA_NAME(@uid)=@dest_owner
        return(0)
    exec @retcode=sys.sp_changeobjectowner @tablename, @dest_owner
    if @@ERROR<>0 or @retcode<>0
    begin
        raiserror(21346, 16, -1, @tablename, @dest_owner)
        return (1)
    end
    return(0)    
GO
GRANT EXECUTE ON [sys].[sp_MSchangeobjectowner] TO [public] AS [dbo]
GO
