SET NOCOUNT ON;
USE master;
CREATE DATABASE rv_fxk3q1_p;
GO
USE rv_fxk3q1_p;
CREATE TABLE dbo.t1 (id int PRIMARY KEY, a int); CREATE TABLE dbo.t2 (id int PRIMARY KEY, a int);
GO
USE master;
EXEC sp_replicationdboption @dbname = N'rv_fxk3q1_p', @optname = N'publish', @value = N'true';
GO
USE rv_fxk3q1_p;
DECLARE @s sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'rv_fxk3q1_pp', @status = N'active', @independent_agent = N'true', @allow_pull = N'true';
EXEC sp_addarticle @publication = N'rv_fxk3q1_pp', @article = N't1', @source_owner = N'dbo', @source_object = N't1';
EXEC sp_addsubscription @publication = N'rv_fxk3q1_pp', @subscriber = @s, @destination_db = N'rv_fxk3q1_s', @article = N'all', @subscription_type = N'pull';
SELECT 'agents_after_pull_add' k, COUNT(*) n FROM distribution.dbo.MSdistribution_agents WHERE publisher_db = N'rv_fxk3q1_p' AND subscriber_db = N'rv_fxk3q1_s';
EXEC sp_addarticle @publication = N'rv_fxk3q1_pp', @article = N't2', @source_owner = N'dbo', @source_object = N't2';
EXEC sp_addsubscription @publication = N'rv_fxk3q1_pp', @subscriber = @s, @destination_db = N'rv_fxk3q1_s', @article = N't2', @subscription_type = N'pull', @sync_type = N'automatic';
SELECT 'agents_after_extend' k, COUNT(*) n FROM distribution.dbo.MSdistribution_agents WHERE publisher_db = N'rv_fxk3q1_p' AND subscriber_db = N'rv_fxk3q1_s';
SELECT 'rows' k, a.name, s.status, s.subscription_type, s.sync_type FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid WHERE s.srvid >= 0 ORDER BY 2;
EXEC sp_dropsubscription @publication = N'rv_fxk3q1_pp', @article = N'all', @subscriber = @s, @destination_db = N'rv_fxk3q1_s';
EXEC sp_droppublication @publication = N'rv_fxk3q1_pp';
GO
USE master;
EXEC sp_replicationdboption @dbname = N'rv_fxk3q1_p', @optname = N'publish', @value = N'false';
ALTER DATABASE rv_fxk3q1_p SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE rv_fxk3q1_p;
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
 (SELECT COUNT(*) FROM distribution.dbo.MSrepl_errors e WHERE e.error_text LIKE N'%rv[_]fx%') errs,
 @@TRANCOUNT tc;
