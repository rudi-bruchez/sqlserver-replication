SET NOCOUNT ON;
USE rv_fxk3q1_p;
DECLARE @s sysname = @@SERVERNAME;
BEGIN TRY EXEC sp_dropsubscription @publication = N'rv_fxk3q1_pi', @article = N'all', @subscriber = @s, @destination_db = N'rv_fxk3q1_s'; END TRY BEGIN CATCH SELECT 'e1', ERROR_NUMBER(), ERROR_MESSAGE(); END CATCH
BEGIN TRY EXEC sp_dropsubscription @publication = N'rv_fxk3q1_pi', @article = N'all', @subscriber = @s, @destination_db = N'rv_fxk3q1_s2'; END TRY BEGIN CATCH SELECT 'e2', ERROR_NUMBER(), ERROR_MESSAGE(); END CATCH
BEGIN TRY EXEC sp_droppublication @publication = N'rv_fxk3q1_pi'; END TRY BEGIN CATCH SELECT 'e3', ERROR_NUMBER(), ERROR_MESSAGE(); END CATCH
GO
USE master;
BEGIN TRY EXEC sp_replicationdboption @dbname = N'rv_fxk3q1_p', @optname = N'publish', @value = N'false'; END TRY BEGIN CATCH SELECT 'e4', ERROR_NUMBER(), ERROR_MESSAGE(); END CATCH
GO
USE master;
ALTER DATABASE rv_fxk3q1_p SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE rv_fxk3q1_p;
ALTER DATABASE rv_fxk3q1_s SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE rv_fxk3q1_s;
ALTER DATABASE rv_fxk3q1_s2 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE rv_fxk3q1_s2;
GO
SET NOCOUNT ON;
SELECT 'residue' k,
 (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'rv[_]fx%') dbs,
 (SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'%rv[_]fx%') jobs,
 (SELECT COUNT(*) FROM distribution.dbo.MSpublications WHERE publisher_db LIKE N'rv[_]fx%') pubs,
 (SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases WHERE publisher_db LIKE N'rv[_]fx%') pubdbs,
 (SELECT COUNT(*) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db LIKE N'rv[_]fx%') lr,
 (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db LIKE N'rv[_]fx%') sa,
 (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents WHERE publisher_db LIKE N'rv[_]fx%') da,
 (SELECT COUNT(*) FROM distribution.dbo.MSsubscriptions WHERE publisher_db LIKE N'rv[_]fx%') subs,
 (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'rv[_]fx%') profiles,
 (SELECT COUNT(*) FROM sys.servers WHERE name LIKE N'rv[_]fx%') servers,
 @@TRANCOUNT tc;
SELECT 'lab' k, (SELECT COUNT(*) FROM Sales.dbo.syspublications) pubs, (SELECT COUNT(*) FROM Sales.dbo.syssubscriptions WHERE srvid>=0) subrows, (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name=N'lab-distrib') labprof;
