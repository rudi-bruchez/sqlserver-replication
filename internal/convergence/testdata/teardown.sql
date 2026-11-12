-- Removes what setup.sql and the plans of the tests create on {db} and
-- {sub}. Each step is in its own TRY so that the rest runs when one fails;
-- the errors are returned at the end. The order: the pull subscriptions,
-- subscriber first (lab/campaign/08-pull.sh, P3.subscriber-first), the
-- subscriptions at the publisher with @article = N'all', the publications,
-- the profiles {prof}, the publish option, then the two databases.
SET NOCOUNT ON;
USE master;
DECLARE @errors nvarchar(max) = N'';
DECLARE @pubsrv sysname, @pubdb sysname, @pub sysname, @srv sysname, @dest sysname, @id int;

IF OBJECT_ID(N'{sub}.dbo.MSreplication_subscriptions', N'U') IS NOT NULL
BEGIN
    DECLARE pulls CURSOR LOCAL STATIC FOR
        -- A push subscription has a row here too (subscription_type 0),
        -- which the distribution agent writes: it is dropped at the publisher.
        SELECT DISTINCT publisher, publisher_db, publication FROM {sub}.dbo.MSreplication_subscriptions
        WHERE subscription_type <> 0;
    OPEN pulls;
    FETCH pulls INTO @pubsrv, @pubdb, @pub;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC {sub}.sys.sp_droppullsubscription @publisher = @pubsrv, @publisher_db = @pubdb, @publication = @pub;
        END TRY
        BEGIN CATCH
            SET @errors += N'sp_droppullsubscription ' + @pub + N': ' + ERROR_MESSAGE() + NCHAR(10);
        END CATCH;
        FETCH pulls INTO @pubsrv, @pubdb, @pub;
    END;
    CLOSE pulls;
    DEALLOCATE pulls;
END;

IF OBJECT_ID(N'{db}.dbo.syssubscriptions', N'U') IS NOT NULL
BEGIN
    DECLARE subs CURSOR LOCAL STATIC FOR
        SELECT DISTINCT p.name, s.srvname, s.dest_db
        FROM {db}.dbo.syssubscriptions AS s
        JOIN {db}.dbo.sysarticles AS a ON a.artid = s.artid
        JOIN {db}.dbo.syspublications AS p ON p.pubid = a.pubid
        WHERE s.srvid >= 0;
    OPEN subs;
    FETCH subs INTO @pub, @srv, @dest;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC {db}.sys.sp_dropsubscription @publication = @pub, @article = N'all', @subscriber = @srv, @destination_db = @dest;
        END TRY
        BEGIN CATCH
            SET @errors += N'sp_dropsubscription ' + @pub + N': ' + ERROR_MESSAGE() + NCHAR(10);
        END CATCH;
        FETCH subs INTO @pub, @srv, @dest;
    END;
    CLOSE subs;
    DEALLOCATE subs;
END;

IF OBJECT_ID(N'{db}.dbo.syspublications', N'U') IS NOT NULL
BEGIN
    DECLARE pubs CURSOR LOCAL STATIC FOR SELECT name FROM {db}.dbo.syspublications;
    OPEN pubs;
    FETCH pubs INTO @pub;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC {db}.sys.sp_droppublication @publication = @pub;
        END TRY
        BEGIN CATCH
            SET @errors += N'sp_droppublication ' + @pub + N': ' + ERROR_MESSAGE() + NCHAR(10);
        END CATCH;
        FETCH pubs INTO @pub;
    END;
    CLOSE pubs;
    DEALLOCATE pubs;
END;

DECLARE profs CURSOR LOCAL STATIC FOR
    SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'{prof}';
OPEN profs;
FETCH profs INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_drop_agent_profile @profile_id = @id;
    END TRY
    BEGIN CATCH
        SET @errors += N'sp_drop_agent_profile {prof}: ' + ERROR_MESSAGE() + NCHAR(10);
    END CATCH;
    FETCH profs INTO @id;
END;
CLOSE profs;
DEALLOCATE profs;

BEGIN TRY
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'{db}' AND is_published = 1)
        EXEC sp_replicationdboption @dbname = N'{db}', @optname = N'publish', @value = N'false';
END TRY
BEGIN CATCH
    SET @errors += N'sp_replicationdboption: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;

BEGIN TRY
    IF DB_ID(N'{sub}') IS NOT NULL
    BEGIN
        ALTER DATABASE {sub} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE {sub};
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE {sub}: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;

BEGIN TRY
    IF DB_ID(N'{db}') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'{db}' AND is_published = 1)
    BEGIN
        ALTER DATABASE {db} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE {db};
    END;
END TRY
BEGIN CATCH
    SET @errors += N'DROP DATABASE {db}: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;

IF @errors <> N''
    THROW 50000, @errors, 1;
