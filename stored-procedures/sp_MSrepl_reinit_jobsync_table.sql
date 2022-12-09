SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_reinit_jobsync_table]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_reinit_jobsync_table] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_reinit_jobsync_table]
	@database_name [sysname],
	@all [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @distdb_name sysname
    declare @cmd nvarchar(4000)
    declare @retval bit

    set @cmd = null

    -- security check
    -- only sysadmin can execute this
    --
    if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
    begin
        raiserror(21089, 16, -1)
        return 1
    end

    if (@all = 1)
    begin
        if (@database_name is not null)
        begin
            raiserror(25028, 16, -1)
            return 1
        end

        -- Skips distribution databases that are either read_only or not accessible.
        declare database_cursor cursor local fast_forward for
        select name as distdb_name
        from sys.databases
        where is_distributor=1
        and databasepropertyex(name, 'Updateability') = N'READ_WRITE'
        and has_dbaccess(name) = 1

        open database_cursor
        fetch next from database_cursor into @distdb_name

        while (@@fetch_status <> -1)
        begin
            select @cmd = @distdb_name + '.sys.sp_MSrepl_reinit_jobsync_table_internal'
            exec @retval = @cmd

            if (@@error <> 0 or @retval <> 0)
                return 1

            fetch next from database_cursor into @distdb_name
        end

        close database_cursor
        deallocate database_cursor
    end 
    else -- for @all = 0
    begin
        if (@database_name is null)
        begin
            set @database_name = db_name()
        end

        if (sys.fn_MSrepl_isdistdb(@database_name) != 1)
        begin
            -- current database is not a distribution database
            raiserror (14117, 16, -1, @database_name)
            return 1
        end

        if (databasepropertyex(@database_name, 'Updateability') = N'READ_ONLY')
        begin
            raiserror(15635, 16, -1, N'sp_MSrepl_reinit_jobsync_table')
            return 1
        end

        if (has_dbaccess(@database_name) <> 1)
        begin
            raiserror(15622, 16, -1, @database_name)
            return 1
        end

        select @cmd = @database_name + '.sys.sp_MSrepl_reinit_jobsync_table_internal'
        exec @retval = @cmd

        if (@@error <> 0 or @retval <> 0)
            return 1
    end

    return 0

end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_reinit_jobsync_table] TO [public] AS [dbo]
GO
