SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplcheck_subscribe]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplcheck_subscribe] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplcheck_subscribe]
WITH EXECUTE AS CALLER
AS
begin
    --
    -- Only the System Administratr (SA) or the Database Owner (dbo) 
    -- can subscribe from the subscribing database.
    --
    -- Do the sysadmin check first as it is 4 times more efficient
    -- than is_member call and reduces performance overhead in case 
    -- the user has sysadmin privileges
    --
    if  is_srvrolemember('sysadmin') = 1 or is_member ('db_owner') = 1 
    begin
        return (0)
    end
    else
    begin
        raiserror (21050, 14, -1)
        return (1)
    end
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplcheck_subscribe] TO [public] AS [dbo]
GO
