SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSremove_mergereplcommand]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSremove_mergereplcommand] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSremove_mergereplcommand]
	@publication [sysname],
	@article [sysname],
	@schematype [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @pubid              uniqueidentifier
    declare @artid              uniqueidentifier
    declare @retcode            int    

    -- added for client requested snapshot to work.
    -- when a non-dbo user comes in only do all checking and subsequent removing if the command exists in the first place.
    exec @retcode=sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@ERROR<>0 return (1)

    select @pubid = pubid FROM dbo.sysmergepublications WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    select @artid = artid FROM dbo.sysmergeextendedarticlesview WHERE name = @article and pubid=@pubid
    if not exists(select * from dbo.sysmergeschemachange where pubid = @pubid and artid = @artid and schematype = @schematype)
        return 0

    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    if @publication IS NULL
    begin
        raiserror (14003, 16, -1)
        return (1)
    end
    
    if @article IS NULL
    begin
        raiserror (20045, 16, -1)
        return (1)
    end

    delete dbo.sysmergeschemachange where pubid = @pubid
                                  and artid = @artid
                             and schematype = @schematype

GO
GRANT EXECUTE ON [sys].[sp_MSremove_mergereplcommand] TO [public] AS [dbo]
GO
