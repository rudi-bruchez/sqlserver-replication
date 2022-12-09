SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getqueuedarticlesynctraninfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getqueuedarticlesynctraninfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getqueuedarticlesynctraninfo]
	@publication [sysname],
	@artid [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@owner sysname
                ,@synctraninsproc sysname
                ,@synctranupdproc sysname
                ,@synctrandelproc sysname
                ,@cftprocname sysname
                ,@articlename sysname
                ,@tablename sysname
    --
    -- security check - should be dbo or sysadmin
    --
    exec @retcode = sp_MSreplcheck_publish
    if @@error != 0 or @retcode != 0
        return 1
    if (object_id(N'dbo.sysarticleupdates') is null
            or object_id(N'dbo.syspublications') is null)
        return 1
    --
    -- get the information needed for resultset
    --
    select schema_name(objectproperty(a.sync_ins_proc, 'SchemaId'))
            ,object_name(a.sync_ins_proc)
            ,object_name(a.sync_upd_proc)
            ,object_name(a.sync_del_proc)
            ,object_name(a.ins_conflict_proc)
            ,art.name
            ,object_name(art.objid)
    from dbo.syspublications p 
        join dbo.sysarticles as art on p.pubid = art.pubid
        join dbo.sysarticleupdates as a on art.artid = a.artid
    where art.artid = @artid
        and p.name = @publication
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_getqueuedarticlesynctraninfo] TO [public] AS [dbo]
GO
