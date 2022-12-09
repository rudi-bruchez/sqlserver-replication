SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_PAL_rolecheck]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_PAL_rolecheck] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_PAL_rolecheck]
	@publication [sysname],
	@artid [uniqueidentifier],
	@repid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@objid [int],
	@tablenick [int],
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
-- sysadmin or db_owner have access
    if is_member('db_owner') = 1 
        return 0

    if (@pubid is not NULL)
    begin
        if (1 <> {fn ISPALUSER(@pubid)})
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@publication is not NULL)
    begin
        if not exists (select * from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name() and (1 = {fn ISPALUSER(pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@artid is not NULL)
    begin
        if not exists (select * from dbo.sysmergearticles where artid = @artid and (1 = {fn ISPALUSER(pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@repid is not NULL)
    begin
        if not exists (select * from dbo.sysmergesubscriptions where subid = @repid and (1 = {fn ISPALUSER(pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@tablenick is not NULL AND @tablenick <> 0)
    begin
        if not exists (select * from dbo.sysmergearticles where nickname = @tablenick and (1 = {fn ISPALUSER(pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@objid is not NULL)
    begin
        if not exists (select * from dbo.sysmergearticles where objid = @objid and (1 = {fn ISPALUSER(pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if (@partition_id is not NULL)
    begin
        if not exists (select * from dbo.MSmerge_partition_groups p1, dbo.sysmergepublications p2 
                        where p1.partition_id = @partition_id and p1.publication_number = p2.publication_number
                            and (1 = {fn ISPALUSER(p2.pubid)}))
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end
    end
    else if not exists(select * from dbo.sysmergepublications where (1 = {fn ISPALUSER(pubid)}))
    begin
        RAISERROR (14126, 11, -1)
        return (1)
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_PAL_rolecheck] TO [public] AS [dbo]
GO
