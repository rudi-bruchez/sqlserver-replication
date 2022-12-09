SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpreplicationdboption]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpreplicationdboption] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpreplicationdboption]
	@dbname [sysname],
	@type [sysname],
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    /*
    ** Declarations.
    */

    DECLARE @retcode int
            ,@typebit int
            ,@distbit int -- bit to distinguish distribution databases
            ,@dbowner bit
            ,@issysadmin bit
            ,@replication_db sysname
            ,@db_category int
            ,@inPAL int
            ,@inPALrole bit
            ,@transpublish bit
            ,@mergepublish bit
            ,@cmd nvarchar(500)

    SELECT @distbit = 16
                -- optimize security check for sysadmin and dbo
                ,@issysadmin = case when (IS_SRVROLEMEMBER(N'sysadmin') = 1) then 1 else 0 end
                ,@inPAL = 0
                ,@inPALrole = 0
                ,@typebit = case 
                                when (lower(@type) like N'publish%') then 1
                                when (lower(@type) like N'subscribe%') then 2
                                when (lower(@type) like N'merge publish%') then 4
                                when (lower(@type) like N'merge subscribe%') then 8
                                when (lower(@type) like N'replication allowed%') then 0
                                else null end

    if @typebit is null
    begin
        raiserror(14091,-1,-1)
        return 1
    end
    --
    -- Parameter Check:  @dbname.
    -- Check to make sure that the database name conforms to the rules
    -- for identifiers.
    --
    IF @dbname <> N'%'
    BEGIN
        EXECUTE @retcode = sys.sp_validname @dbname
        IF @@ERROR <> 0 OR @retcode <> 0
        RETURN (1)
    END

    --
    -- create temp table for resultset
    --
    CREATE TABLE #replicationdbs 
    (
        name sysname primary key, 
        id int identity NOT NULL, 
        transpublish bit not null, 
        mergepublish bit not null, 
        dbowner bit not null, 
        dbreadonly bit not null,
        haspublications bit NULL,
        haspullsubscriptions bit NULL
    )
    --
    -- populate the table
    --
    INSERT INTO #replicationdbs (name, transpublish, mergepublish, dbowner, dbreadonly) 
        SELECT name 
                ,is_published
                ,is_merge_published
                ,case when (@issysadmin = 1) then 1 else 0 end
                ,is_read_only
        FROM master.sys.databases
        WHERE ((@dbname = N'%') OR (name = @dbname))
            AND ((@typebit = 0) or (is_published = 1) or (is_merge_published = 1) or (is_subscribed = 1))
            AND (HAS_DBACCESS ( name ) = 1)
            AND (@typebit != 0 OR is_distributor = 0) --Filter out distribution databases
            AND (@typebit != 0 OR name not in (N'master',N'model',N'tempdb',N'msdb',N'MSSQLWeb')) -- filter our system dbs
            AND source_database_id is NULL -- exclude snapshot files

    --
    -- enumerate database collection
    --
    DECLARE #hCdboinfo CURSOR LOCAL FAST_FORWARD FOR
        SELECT name, transpublish, mergepublish, dbowner
        FROM #replicationdbs

    OPEN #hCdboinfo
    FETCH #hCdboinfo INTO @replication_db, @transpublish, @mergepublish, @dbowner
    WHILE (@@fetch_status <> -1)
    BEGIN
        --
        -- initialize
        --
        select @inPAL = 0
                ,@inPALrole = 0
        --
        -- skip dbowner check when sysadmin
        --
        if (@dbowner = 0)
        begin
            exec @dbowner = sys.sp_MSrepl_isdbowner @dbname = @replication_db
            if (@dbowner = 1)
            begin
                update #replicationdbs
                set dbowner = 1
                where name = @replication_db
            end
        end
        --
        -- skip PAL check when sysadmin or dbo
        --
        if (@dbowner = 0)
        begin
            --
            -- Check to see if the user has PAL access to a database publication
            --
            if (@transpublish = 1)
            begin
                -- Check PAL for transactional publication
                select @cmd = quotename(@replication_db) + N'.sys.sp_MScheck_palroleinpubdb '
                EXEC @retcode = @cmd @login = NULL 
                                            ,@hasaccess = @inPAL output
            end

            if (@mergepublish = 1)
            begin
                -- Check PAL role for merge publication
                select @cmd = quotename(@replication_db) + N'.sys.sp_MSrepl_IsUserInAnyPAL '
                EXEC @retcode = @cmd
                    @raise_error = 0
                if @@error = 0 and @retcode = 0
                    select @inPALrole = 1
            end
        end
        --
        -- Valid entry if user has access
        --
        if (@dbowner = 0 and @inPAL = 0 and @inPALrole = 0)
        begin
            DELETE #replicationdbs where name = @replication_db
        end
        else if (@reserved = 1)
        begin
            --
            -- get publication and pull subscription information
            --
            select @cmd = quotename(@replication_db) + N'.sys.sp_MSrepl_helpreplicationdboptionex '
            EXEC @retcode = @cmd  
                @name = @replication_db
                ,@transpublish = @transpublish
                ,@mergepublish = @mergepublish
        end
        --
        -- get next db entry
        --
        FETCH #hCdboinfo INTO @replication_db, @transpublish, @mergepublish, @dbowner
    END
    CLOSE #hCdboinfo
    DEALLOCATE #hCdboinfo
    --
    -- return resultset
    --
    if (@reserved = 0)
    begin
        SELECT 
                name  
                ,id
                ,transpublish
                ,mergepublish
                ,dbowner 
                ,dbreadonly
        FROM #replicationdbs order by name
    end
    else
    begin
        SELECT 
                name  
                ,id
                ,transpublish
                ,mergepublish
                ,dbowner 
                ,dbreadonly
                ,haspublications
                ,haspullsubscriptions
        FROM #replicationdbs order by name
    end
    -- all done
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_helpreplicationdboption] TO [public] AS [dbo]
GO
