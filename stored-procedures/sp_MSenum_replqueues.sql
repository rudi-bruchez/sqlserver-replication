SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_replqueues]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_replqueues] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_replqueues]
	@curdistdb [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @distbit int
    declare @db_name sysname
    declare @cmd nvarchar(1024)

    select @distbit = 16

    --
    -- create the temp table to store the relevant information
    --
    create table #replqueue (
        queue_server sysname collate database_default not null,
        queue_id sysname collate database_default not null,
        dist_db sysname collate database_default not null
    )
    create unique clustered index ucreplqueue ON #replqueue (queue_id)

    --
    -- Has the user specified a distribution database
    --
    if (@curdistdb is NULL)
    begin
        --
        -- Go through all the distribution databases
        --
        declare hCdatabase CURSOR LOCAL FAST_FORWARD FOR 
            select name from master.dbo.sysdatabases 
            where
                category & @distbit <> 0 and
                has_dbaccess(name) = 1
            for read only
    end
    else
    begin
        --
        -- User specified Distribution Database
        -- Validate the user specified name
        --
        if exists (select name from master.dbo.sysdatabases 
        where
            name = @curdistdb and
            category & @distbit <> 0 and
            has_dbaccess(name) = 1)
        begin
            declare hCdatabase CURSOR LOCAL FAST_FORWARD FOR
            select @curdistdb
            for read only
        end
        else
        begin
            --
            -- Error : Invalid distribution db specified
            --
            raiserror(20587, 16, 4, N'@curdistdb', N'sp_MSenum_replqueues')
            return 1
        end
    end

    --
    -- Enumerate
    --
    open hCdatabase
    fetch next from hCdatabase into @db_name
    while (@@fetch_status <> -1)
    begin
        select @cmd =
        'SET NOCOUNT ON ' +
        'INSERT INTO #replqueue (queue_server, queue_id, dist_db) ' +
        'SELECT queue_server, queue_id, ' +
                'N''' + replace(@db_name, '''', '''''') + ''' ' +
        'FROM ' +
                QUOTENAME(@db_name) + '.dbo.MSdistribution_agents ' +
        'WHERE ' +
                'queue_id IS NOT NULL and queue_id != N''mssqlqueue'''
            
        exec (@cmd)
        fetch next from hCdatabase into @db_name
    end
    close hCdatabase
    deallocate hCdatabase

    --
    -- select the contents of the temp table to present
    -- the formatted queue name
    --
    select     N'DIRECT=OS:' + queue_server + N'\PRIVATE$\' + queue_id AS 'queue_format'
            ,dist_db
    from #replqueue
    
    --
    -- cleanup
    --
    drop table #replqueue
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_replqueues] TO [public] AS [dbo]
GO
