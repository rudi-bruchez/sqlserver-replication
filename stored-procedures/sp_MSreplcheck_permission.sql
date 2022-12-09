SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplcheck_permission]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplcheck_permission] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplcheck_permission]
	@objid [int],
	@type [int],
	@permissions [int]
WITH EXECUTE AS CALLER
AS
declare @tablename sysname
    declare @ownername  sysname
    declare @unqual_sourcename nvarchar(540)

    select @ownername=SCHEMA_NAME(schema_id) from sys.objects where object_id=@objid
    select @tablename=object_name(@objid)

    -- bypass this checking for dbo or member of db_owner.
    if is_srvrolemember('sysadmin') = 1 or is_member ('db_owner') = 1
        return (0)
        
    if @permissions=0
        return (0)
        
    select @unqual_sourcename = sys.fn_replreplacesinglequote(@ownername + '.' + @tablename)

    --insert
    if @type=1 and @permissions & 1 = 1 and HAS_PERMS_BY_NAME(@unqual_sourcename, 'OBJECT', 'INSERT')=0
        return (1)

    --update        
    if @type=2 and @permissions & 2 = 2 and HAS_PERMS_BY_NAME(@unqual_sourcename, 'OBJECT', 'UPDATE')=0
        return (1)

    --delete
    if @type=3 and @permissions & 4 = 4 and HAS_PERMS_BY_NAME(@unqual_sourcename, 'OBJECT', 'DELETE')=0
        return (1) 
        
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSreplcheck_permission] TO [public] AS [dbo]
GO
