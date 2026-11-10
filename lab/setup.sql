-- Lab replication for sqlrepl: local distributor, publisher and subscriber on one
-- SQL Server Developer instance (Linux container, SQL Agent enabled).
-- Run as sa. Idempotent only on a fresh instance; use teardown.sql to start over.
SET NOCOUNT ON;
USE master;
GO
DECLARE @srv sysname = @@SERVERNAME;
-- The working directory must exist and belong to mssql: see lab/README.md.
IF NOT EXISTS (SELECT * FROM sys.servers WHERE name = N'repl_distributor')
    EXEC sp_adddistributor @distributor = @srv, @password = N'';
IF DB_ID(N'distribution') IS NULL
    EXEC sp_adddistributiondb @database = N'distribution', @security_mode = 1;
EXEC sp_adddistpublisher @publisher = @srv, @distribution_db = N'distribution',
     @security_mode = 1, @working_directory = N'/var/opt/mssql/data/ReplData';
GO
CREATE DATABASE Sales;
CREATE DATABASE SalesSub;
GO
USE Sales;
GO
CREATE TABLE dbo.Customer (
    CustomerID int NOT NULL PRIMARY KEY,
    Name nvarchar(100) NOT NULL,
    Country char(2) NOT NULL,
    Notes nvarchar(max) NULL);
CREATE TABLE dbo.Orders (
    OrderID int NOT NULL PRIMARY KEY,
    CustomerID int NOT NULL REFERENCES dbo.Customer,
    Amount decimal(12,2) NOT NULL);
CREATE TABLE dbo.Product (
    ProductID int NOT NULL PRIMARY KEY,
    Label nvarchar(100) NOT NULL);
GO
CREATE VIEW dbo.vCustomerFR AS SELECT CustomerID, Name FROM dbo.Customer WHERE Country = 'FR';
GO
INSERT dbo.Customer VALUES (1, N'Alpha', 'FR', NULL), (2, N'Beta', 'DE', N'x');
INSERT dbo.Orders VALUES (10, 1, 12.50), (11, 2, 99.00);
INSERT dbo.Product VALUES (100, N'Widget');
GO
EXEC sp_replicationdboption @dbname = N'Sales', @optname = N'publish', @value = N'true';
EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
GO
-- Publication 1: independent agent, immediate_sync, filters, custom commands.
EXEC sp_addpublication @publication = N'SalesPub', @status = N'active',
     @allow_push = N'true', @allow_pull = N'true', @independent_agent = N'true',
     @immediate_sync = N'true', @repl_freq = N'continuous', @sync_method = N'concurrent',
     @retention = 0, @description = N'lab publication';
EXEC sp_addpublication_snapshot @publication = N'SalesPub',
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'SalesPub', @article = N'Customer',
     @source_owner = N'dbo', @source_object = N'Customer',
     @filter_clause = N'Country = ''FR''', @schema_option = 0x000000000803509F;
EXEC sp_articlefilter @publication = N'SalesPub', @article = N'Customer',
     @filter_name = N'FLTR_Customer', @filter_clause = N'Country = ''FR''';
EXEC sp_articlecolumn @publication = N'SalesPub', @article = N'Customer',
     @column = N'Notes', @operation = N'drop', @force_invalidate_snapshot = 1;
EXEC sp_articleview @publication = N'SalesPub', @article = N'Customer',
     @view_name = N'SYNC_Customer', @filter_clause = N'Country = ''FR''',
     @force_invalidate_snapshot = 1;
EXEC sp_addarticle @publication = N'SalesPub', @article = N'Orders',
     @source_owner = N'dbo', @source_object = N'Orders',
     @destination_table = N'OrdersCopy', @pre_creation_cmd = N'truncate',
     @ins_cmd = N'SQL', @upd_cmd = N'SCALL sp_MSupd_dboOrders',
     @del_cmd = N'XCALL custom_del_Orders';
GO
-- Publication 2: shared distribution agent, schema-only article.
EXEC sp_addpublication @publication = N'SalesRef', @status = N'active',
     @allow_push = N'true', @independent_agent = N'false', @immediate_sync = N'false',
     @repl_freq = N'continuous', @sync_method = N'native';
EXEC sp_addpublication_snapshot @publication = N'SalesRef',
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'SalesRef', @article = N'Product',
     @source_owner = N'dbo', @source_object = N'Product';
EXEC sp_addarticle @publication = N'SalesRef', @article = N'vCustomerFR',
     @source_owner = N'dbo', @source_object = N'vCustomerFR', @type = N'view schema only';
GO
-- Push subscriptions to SalesSub on the same instance.
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'SalesPub', @subscriber = @srv,
     @destination_db = N'SalesSub', @subscription_type = N'Push', @sync_type = N'automatic';
EXEC sp_addpushsubscription_agent @publication = N'SalesPub', @subscriber = @srv,
     @subscriber_db = N'SalesSub', @job_login = NULL, @job_password = NULL,
     @subscriber_security_mode = 1;
EXEC sp_addsubscription @publication = N'SalesRef', @subscriber = @srv,
     @destination_db = N'SalesSub', @subscription_type = N'Push', @sync_type = N'automatic',
     @article = N'all';
EXEC sp_addpushsubscription_agent @publication = N'SalesRef', @subscriber = @srv,
     @subscriber_db = N'SalesSub', @job_login = NULL, @job_password = NULL,
     @subscriber_security_mode = 1;
GO
-- A user-defined distribution agent profile.
DECLARE @pid int;
EXEC msdb.dbo.sp_add_agent_profile @profile_id = @pid OUTPUT,
     @profile_name = N'lab-distrib', @agent_type = 3, @profile_type = 1,
     @description = N'lab profile';
-- A new profile starts as a copy of the default profile's parameters, so change, not add.
EXEC msdb.dbo.sp_change_agent_parameter @profile_id = @pid,
     @parameter_name = N'-CommitBatchSize', @parameter_value = N'200';
GO
EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'SalesPub';
EXEC Sales.dbo.sp_startpublication_snapshot @publication = N'SalesRef';
GO
