SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_DDL_after_regular_snapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_DDL_after_regular_snapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_DDL_after_regular_snapshot]
	@publication [sysname],
	@ddl_present [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @pubid uniqueidentifier
    declare @schemaversion_of_snapshot_trailer int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode <> 0 or @@error <> 0
        return 1

    select @pubid = pubid from dbo.sysmergepublications  
            where name=@publication and upper(publisher)=upper(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL 
    begin
        RAISERROR (20026, 16, -1, @publication)
        return 1
    end

    select @schemaversion_of_snapshot_trailer = schemaversion from dbo.sysmergeschemachange 
        where pubid = @pubid and schematype = 52
    if @schemaversion_of_snapshot_trailer is NULL
    begin
        raiserror(20652, 16, -1, @publication)
        return 1
    end

    if exists (select * from dbo.sysmergeschemachange 
                where pubid = @pubid and schemaversion > @schemaversion_of_snapshot_trailer and
                      schematype in (11, 13, 300))
        select @ddl_present = 1
    else
        select @ddl_present = 0

GO
GRANT EXECUTE ON [sys].[sp_MSget_DDL_after_regular_snapshot] TO [public] AS [dbo]
GO
