SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_cleanupdbreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_cleanupdbreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_cleanupdbreplication]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @pubid            uniqueidentifier    
    declare @artid            uniqueidentifier
    declare @retcode        int

    exec @retcode = sys.sp_MSreplcheck_publish
    if (@retcode <> 0 or @@error <> 0)
        return 1

    if object_id('sysmergesubscriptions') is NULL
        return (0)
    declare #RemoveReplication CURSOR LOCAL FAST_FORWARD for 
        select pubid from dbo.sysmergepublications 
    open #RemoveReplication
    fetch #RemoveReplication into @pubid
    while (@@fetch_status<>-1)
    begin
        /* Clean up the articles for this publication, and delete the row */
        select @artid = artid FROM dbo.sysmergearticles WHERE pubid = @pubid
        while @artid is not null
        begin
            if not exists (select * from dbo.sysmergearticles WHERE artid = @artid and pubid <> @pubid)
            begin
                exec @retcode=sys.sp_MSarticlecleanup @pubid, @artid, 1
                if @retcode<>0 or @@ERROR<>0 
                begin
                    close #RemoveReplication
                    deallocate #RemoveReplication
                    return (1)
                end
            end

            delete from dbo.sysmergepartitioninfo where artid = @artid and pubid = @pubid
            delete from dbo.sysmergearticles where artid = @artid and pubid = @pubid
            set @artid = NULL
            select @artid = artid FROM dbo.sysmergearticles WHERE pubid = @pubid
        end
        fetch #RemoveReplication into @pubid
    end
    close #RemoveReplication
    deallocate #RemoveReplication
            
    /* Now clean up any traces in other system tables */

    if object_id('MSmerge_generation_partition_mappings', 'U') is not NULL
        truncate table dbo.MSmerge_generation_partition_mappings    
    if object_id('MSmerge_genhistory', 'U') is not NULL
        truncate table dbo.MSmerge_genhistory 
    if object_id('MSmerge_replinfo', 'U') is not NULL
        truncate table dbo.MSmerge_replinfo
    if object_id('sysmergesubsetfilters', 'U') is not NULL
        truncate table dbo.sysmergesubsetfilters 
    if object_id('sysmergesubscriptions', 'U') is not NULL
        truncate table dbo.sysmergesubscriptions 
    
    if object_id('MSmerge_history', 'U') is not NULL
        truncate table dbo.MSmerge_history 
    if object_id('MSrepl_errors', 'U') is not NULL
        truncate table dbo.MSrepl_errors 
    if object_id('MSmerge_articlehistory', 'U') is not NULL
        truncate table dbo.MSmerge_articlehistory 
    if object_id('MSmerge_sessions', 'U') is not NULL
        truncate table dbo.MSmerge_sessions 
    
    if object_id('MSmerge_current_partition_mappings', 'U') is not NULL
        truncate table dbo.MSmerge_current_partition_mappings
    if object_id('MSmerge_past_partition_mappings', 'U') is not NULL
        truncate table dbo.MSmerge_past_partition_mappings
    -- cannot use truncate table on MSmerge_partition_groups because it is referenced by an FK.
    if object_id('MSmerge_partition_groups', 'U') is not NULL
        delete from dbo.MSmerge_partition_groups
    if object_id('sysmergepublications', 'U') is not NULL
        truncate table dbo.sysmergepublications
    if object_id('sysmergeschemachange', 'U') is not NULL
        truncate table dbo.sysmergeschemachange
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_cleanupdbreplication] TO [public] AS [dbo]
GO
