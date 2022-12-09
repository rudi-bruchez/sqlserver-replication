SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscript_dri]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscript_dri] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscript_dri]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid    uniqueidentifier
    
select @pubid = pubid from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
        
-- Security check
if (1 <> {fn ISPALUSER(@pubid)} and
    1 <> is_member('db_owner'))
begin    
    RAISERROR (15247, 11, -1)
    return (1)
end

select referenced_object_id, parent_object_id from sys.foreign_keys 
        where parent_object_id in (select objid from dbo.sysmergearticles where pubid = @pubid and name = @article) 
            and referenced_object_id not in (select objid from dbo.sysmergearticles where pubid = @pubid)
GO
GRANT EXECUTE ON [sys].[sp_MSscript_dri] TO [public] AS [dbo]
GO
