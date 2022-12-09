SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergepartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergepartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergepartition]
	@publication [sysname],
	@suser_sname [sysname],
	@host_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    declare @uses_suser_sname bit
    declare @uses_host_name bit
    declare @pubid uniqueidentifier
    declare @command nvarchar(2000)
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1
        
    select @pubid = pubid from dbo.sysmergepublications     
                where name = @publication and
                    UPPER(publisher) = UPPER(publishingservername()) and
                    publisher_db = db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 11, -1, @publication)
        return (1)
    end
    
    if @suser_sname is NULL or ltrim(rtrim(@suser_sname)) = N''
        select @suser_sname = NULL
    if @host_name is NULL or ltrim(rtrim(@host_name)) = N''
        select @host_name = NULL
        
    exec @retcode = sys.sp_MSget_dynamic_filtering_information 
                        @pubid = @pubid, 
                        @uses_host_name = @uses_host_name OUTPUT,
                        @uses_suser_sname = @uses_suser_sname OUTPUT
    if @@error <> 0 or @retcode <> 0
        return 1

    -- if the publication does not use suser_sname for filtering and the user has specified
    -- a value for suser_sname raise an error.
    if @uses_suser_sname = 0 and @suser_sname is not NULL
    begin
        raiserror(20673, 16, -1)
        return 1
    end
    
    -- if the publication does not use host_name for filtering and the user has specified
    -- a value for host_name raise an error.
    if @uses_host_name = 0 and @host_name is not NULL
    begin
        raiserror(20672, 16, -1)
        return 1
    end
    
    select @command = 'select part.partition_id as partition,'
    
   if @uses_host_name = 1 and exists (select * from sys.columns where name = 'HOST_NAME_FN'
												and object_id = object_id('dbo.MSmerge_partition_groups'))
        select @command = @command + ' part.HOST_NAME_FN as host_name,'
    else
        select @command = @command + ' NULL as host_name,'

    if @uses_suser_sname = 1 and exists (select * from sys.columns where name = 'SUSER_SNAME_FN'
												and object_id = object_id('dbo.MSmerge_partition_groups'))
        select @command = @command + ' part.SUSER_SNAME_FN as suser_sname,'
    else
        select @command = @command + ' NULL as suser_sname,'

    select @command = @command + '
               dyn.dynamic_snapshot_location as dynamic_snaphsot_location,
               dyn.last_updated as date_refreshed,
               dynjobs.job_id as dynamic_snapshot_jobid
        from dbo.MSmerge_partition_groups part 
          inner join dbo.sysmergepublications pub on part.publication_number = pub.publication_number
          left outer join dbo.MSmerge_dynamic_snapshots dyn on part.partition_id = dyn.partition_id 
          left outer join dbo.MSdynamicsnapshotjobs dynjobs on part.partition_id = dynjobs.partition_id
        where pub.pubid = ''' + convert(nvarchar(36),@pubid) + ''''

    if @suser_sname is not NULL
        select @command = @command + ' and part.SUSER_SNAME_FN = ' + quotename(@suser_sname, '''') 
    if @host_name is not NULL
        select @command = @command + ' and part.HOST_NAME_FN = ' + quotename(@host_name, '''') 

    exec (@command)
end
GO
GRANT EXECUTE ON [sys].[sp_helpmergepartition] TO [public] AS [dbo]
GO
