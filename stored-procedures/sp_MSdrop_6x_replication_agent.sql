SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_6x_replication_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_6x_replication_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_6x_replication_agent]
	@job_id [uniqueidentifier],
	@category_id [int]
WITH EXECUTE AS CALLER
AS
declare @distbit int
    declare @db_name sysname
    declare @cmd nvarchar(4000)

    select @distbit = 16

    -- Only perform cleanup of 6x replication agent if caller 
    -- is sysadmin member. This is compromise between the need to 
    -- maintain very old (and deprecated) functionality and the 
    -- need to keep things secured 
    if is_srvrolemember('sysadmin') <> 1
        return 0

    declare hCdatabase CURSOR LOCAL FAST_FORWARD FOR
        select name from master.dbo.sysdatabases 
            where
            category & @distbit <> 0 
        for read only

    open hCdatabase
    fetch next from hCdatabase into @db_name
    while (@@fetch_status <> -1)
    begin

        if @category_id = 13
        begin
            select @cmd = N'delete from ' + QUOTENAME(@db_name) + N'.dbo.MSlogreader_agents where job_id = convert (uniqueidentifier, ''' +
                convert (nvarchar(100), @job_id) + N''')'
            exec (@cmd)
        end
        else if @category_id = 15   
        begin
            select @cmd = QUOTENAME(@db_name) + N'.dbo.sp_MSdrop_6x_publication'
            exec @cmd @job_id = @job_id
        end
        else
            return 0

        if @@ERROR <> 0
            return 1
        
        fetch next from hCdatabase into @db_name
    end
    close hCdatabase
    deallocate hCdatabase
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_6x_replication_agent] TO [public] AS [dbo]
GO
