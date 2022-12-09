SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergepartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergepartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergepartition]
	@publication [sysname],
	@suser_sname [sysname],
	@host_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    declare @pubid uniqueidentifier
    declare @partition_id int
    declare @pub_number smallint
    declare @dynamic_snapshot_jobname sysname
    declare @dynamic_filters bit

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1
        
    select @pubid = pubid, @dynamic_filters = dynamic_filters, @pub_number = publication_number from dbo.sysmergepublications     
                where name = @publication and
                    UPPER(publisher) = UPPER(publishingservername()) and
                    publisher_db = db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 11, -1, @publication)
        return (1)
    end
    
    -- The given publication must be enabled for dynamic filtering
    if @dynamic_filters <> 1
    begin
        raiserror(20674, 16, -1)
        return (1)
    end
    
    if @suser_sname is NULL or ltrim(rtrim(@suser_sname)) = N''
        select @suser_sname = NULL
    if @host_name is NULL or ltrim(rtrim(@host_name)) = N''
        select @host_name = NULL
        
    exec @retcode = sys.sp_MScheck_dynamic_filtering_information 
                        @pubid = @pubid, 
                        @dynamic_filter_login = @suser_sname,
                        @dynamic_filter_hostname = @host_name
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
    end

    exec @retcode = sys.sp_MSget_subscriber_partition_id 
                        @publication,
                        @partition_id output,
                        NULL,
                        @host_name,
                        @suser_sname
    if @@error <> 0 or @retcode <> 0
        return 1

    if @partition_id is NULL
        return 0

    select @dynamic_snapshot_jobname = name from dbo.MSdynamicsnapshotjobs where partition_id = @partition_id
    if (@dynamic_snapshot_jobname is not NULL)
    begin
        exec @retcode = sys.sp_dropdynamicsnapshot_job @publication, @dynamic_snapshot_jobname
    end

    -- delete the dynamic snapshot files
    exec @retcode = sys.sp_MSclear_dynamic_snapshot_location @publication, @partition_id, 1

    delete from MSmerge_current_partition_mappings where partition_id = @partition_id and publication_number = @pub_number
    delete from MSmerge_past_partition_mappings where partition_id = @partition_id and publication_number = @pub_number
    delete from MSmerge_generation_partition_mappings where partition_id = @partition_id
    delete from MSmerge_partition_groups where partition_id = @partition_id

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_dropmergepartition] TO [public] AS [dbo]
GO
