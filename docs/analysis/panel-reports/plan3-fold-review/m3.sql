SET NOCOUNT ON;
USE master;
CREATE DATABASE rv_fxk3q1_p; CREATE DATABASE rv_fxk3q1_s; CREATE DATABASE rv_fxk3q1_s2;
GO
USE rv_fxk3q1_p;
CREATE TABLE dbo.t1 (id int PRIMARY KEY, a int); CREATE TABLE dbo.t2 (id int PRIMARY KEY, a int); CREATE TABLE dbo.t3 (id int PRIMARY KEY, a int);
GO
USE master;
EXEC sp_replicationdboption @dbname = N'rv_fxk3q1_p', @optname = N'publish', @value = N'true';
GO
USE rv_fxk3q1_p;
DECLARE @s sysname = @@SERVERNAME;
EXEC sp_addpublication @publication = N'rv_fxk3q1_pi', @status = N'active', @independent_agent = N'true', @immediate_sync = N'true';
SELECT 'snapagent_before' k, local_job, CONVERT(nvarchar(36), CONVERT(uniqueidentifier, job_id)) job, (SELECT COUNT(*) FROM msdb.dbo.sysjobs j WHERE j.job_id = CONVERT(uniqueidentifier, a.job_id)) job_exists FROM distribution.dbo.MSsnapshot_agents a WHERE publisher_db = N'rv_fxk3q1_p';
SELECT 'logreader' k, COUNT(*) n FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'rv_fxk3q1_p';
EXEC sp_addarticle @publication = N'rv_fxk3q1_pi', @article = N't1', @source_owner = N'dbo', @source_object = N't1';
EXEC sp_addarticle @publication = N'rv_fxk3q1_pi', @article = N't2', @source_owner = N'dbo', @source_object = N't2';
EXEC sp_addsubscription @publication = N'rv_fxk3q1_pi', @subscriber = @s, @destination_db = N'rv_fxk3q1_s', @article = N'all';
EXEC sp_addsubscription @publication = N'rv_fxk3q1_pi', @subscriber = @s, @destination_db = N'rv_fxk3q1_s2', @article = N'all', @sync_type = N'replication support only';
SELECT 'rows_initial' k, s.dest_db, a.name, s.status, s.sync_type FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid WHERE s.srvid >= 0 ORDER BY 2,3;
-- R35: interrupted article drop, then the manual repair the refusal names
EXEC sp_dropsubscription @publication = N'rv_fxk3q1_pi', @article = N't2', @subscriber = @s, @destination_db = N'rv_fxk3q1_s';
SELECT 'rows_after_drop_t2' k, s.dest_db, a.name, s.status FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid WHERE s.srvid >= 0 AND s.dest_db = N'rv_fxk3q1_s' ORDER BY 2,3;
BEGIN TRY
EXEC sp_reinitsubscription @publication = N'rv_fxk3q1_pi', @article = N'all', @subscriber = @s, @destination_db = N'rv_fxk3q1_s';
END TRY BEGIN CATCH SELECT 'reinit_err' k, ERROR_NUMBER() n, ERROR_MESSAGE() m; END CATCH
SELECT 'rows_after_reinit' k, s.dest_db, a.name, s.status FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid WHERE s.srvid >= 0 AND s.dest_db = N'rv_fxk3q1_s' ORDER BY 2,3;
-- sp_addarticle on an immediate_sync publication with a replication support only subscription
EXEC sp_addarticle @publication = N'rv_fxk3q1_pi', @article = N't3', @source_owner = N'dbo', @source_object = N't3';
SELECT 'rows_after_add_t3' k, s.dest_db, a.name, s.status, s.sync_type FROM dbo.syssubscriptions s JOIN dbo.sysarticles a ON a.artid = s.artid WHERE s.srvid >= 0 ORDER BY 2,3;
SELECT 'trancount' k, @@TRANCOUNT tc;
GO
