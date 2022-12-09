SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replication_agent_checkup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replication_agent_checkup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replication_agent_checkup]
	@heartbeat_interval [int]
WITH EXECUTE AS CALLER
AS
declare @distribution_db sysname
	declare @retstatus int
	declare @proc nvarchar(255)
	declare @retcode int

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

    declare hCdistdbs CURSOR LOCAL FAST_FORWARD for
        select name from msdb..MSdistributiondbs where 
            has_dbaccess(name) = 1
            and databasepropertyex(name, 'Updateability') = N'READ_WRITE'
    for read only
    open hCdistdbs
    fetch hCdistdbs into @distribution_db
    while @@fetch_status <> -1
    begin
        select @proc = QUOTENAME(@distribution_db) + '.sys.sp_MSagent_retry_stethoscope'
        execute  @retcode = @proc 
        if @@error <> 0 or @retcode <> 0
        begin
            select @retstatus = 1
            goto UNDO
        end
        
        select @proc = QUOTENAME(@distribution_db) + '.sys.sp_MSagent_stethoscope'
        execute  @retcode = @proc @heartbeat_interval
        if @@error <> 0 or @retcode <> 0
        begin
            select @retstatus = 1
            goto UNDO
        end
        fetch hCdistdbs into @distribution_db
    end

	set @retstatus = 0

UNDO:
	close hCdistdbs
	deallocate hCdistdbs
	return (@retstatus)
GO
GRANT EXECUTE ON [sys].[sp_replication_agent_checkup] TO [public] AS [dbo]
GO
