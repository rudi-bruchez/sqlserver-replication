SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergepartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergepartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergepartition]
	@publication [sysname],
	@suser_sname [sysname],
	@host_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    declare @pubid uniqueidentifier
    declare @partition_id int
    declare @dynamic_filters bit
    
    select @dynamic_filters = 0

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1
        
    select @pubid = pubid, @dynamic_filters = dynamic_filters from dbo.sysmergepublications     
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

    if @suser_sname is not NULL
    begin
        -- Check that the given dynammic filter login is in the PAL
        exec @retcode = sys.sp_check_publication_access
                    @publication = @publication,
                    @given_login = @suser_sname
        if @retcode <> 0 or @@error <> 0
            return 1
    end


    exec @retcode = sys.sp_MSget_subscriber_partition_id 
                        @publication,
                        @partition_id output,
                        NULL,
                        @host_name,
                        @suser_sname
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(20629, 16, -1)
        return (1)
    end

    select @partition_id
    
end
GO
GRANT EXECUTE ON [sys].[sp_addmergepartition] TO [public] AS [dbo]
GO
