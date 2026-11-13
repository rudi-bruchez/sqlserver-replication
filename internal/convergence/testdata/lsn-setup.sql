-- Backs {db} up COPY_ONLY to {bak} and restores it over {sub}, the
-- subscriber of an initialization from an LSN (R57, 10-init-modes I3).
-- teardown.sql deletes the file and the backup and restore history.
SET NOCOUNT ON;
USE master;
BACKUP DATABASE {db} TO DISK = N'{bak}' WITH INIT, COPY_ONLY;
GO
ALTER DATABASE {sub} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
RESTORE DATABASE {sub} FROM DISK = N'{bak}' WITH REPLACE, RECOVERY,
    MOVE N'{db}' TO N'/var/opt/mssql/data/{sub}.mdf',
    MOVE N'{db}_log' TO N'/var/opt/mssql/data/{sub}_log.ldf';
GO
ALTER DATABASE {sub} SET MULTI_USER;
