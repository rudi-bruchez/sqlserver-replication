SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdodatabasesnapshotinitiation]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdodatabasesnapshotinitiation] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdodatabasesnapshotinitiation]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    if @@trancount < 1 return 1

    if sessionproperty('replication_agent') <> 1 return 1

    if object_id(N'dbo.syspublications', 'U') is null return 1

    declare @retcode int
    set @retcode = 0

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    declare @qualifiedname nvarchar(520),
            @objid int,
            @articletype tinyint,
            @pubid int,
            @repl_freq tinyint,
            @error int

    set @pubid = null
    set @error = 0

    select @pubid = pubid,
           @repl_freq = repl_freq
      from dbo.syspublications
     where name = @publication

    if @pubid is null return 1

        update dbo.syssubscriptions
           set status = 3
          from dbo.syssubscriptions subs
    inner join dbo.sysextendedarticlesview arts
            on subs.artid = arts.artid
         where arts.pubid = @pubid
           and (subs.status in (0, 1) and subs.sync_type = 1 
                or subs.srvid = -1)

    update dbo.sysarticles
       set status = status | 1
     where artid in
        (select subs.artid
           from syssubscriptions subs
     inner join dbo.sysarticles arts
             on subs.artid = arts.artid
          where arts.pubid = @pubid)

    update dbo.sysschemaarticles
       set status = status | 1
     where artid in
        (select subs.artid
           from syssubscriptions subs
     inner join dbo.sysschemaarticles arts
             on subs.artid = arts.artid
          where arts.pubid = @pubid)

    exec @retcode = sys.sp_replflush          
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSdodatabasesnapshotinitiation] TO [public] AS [dbo]
GO
