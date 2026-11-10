-- Impact matrix (docs/analysis/step-1-analysis.md, section 5), run after setup.sql
-- once both snapshots have been delivered. Each case runs inside a transaction
-- that is rolled back, so every case starts from the same state: valid
-- snapshot, active subscription. It is run four times, with
-- (@force_invalidate_snapshot, @force_reinit_subscription) = (0,0), (1,0),
-- (0,1), (1,1); a cell is "ok" or the error number.
--   20607: needs @force_invalidate_snapshot = 1
--   20608: needs @force_reinit_subscription = 1
SET NOCOUNT ON;
USE Sales;
GO
DECLARE @cases TABLE (id int IDENTITY, label nvarchar(200), stmt nvarchar(max));
DECLARE @cp nvarchar(max) = N'EXEC sp_changepublication @publication = N''{pub}'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';
DECLARE @ca nvarchar(max) = N'EXEC sp_changearticle @publication = N''{pub}'', @article = N''{art}'', @property = N''{prop}'', @value = N''{val}'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r';

-- Publication properties. SalesPub: immediate_sync = 1, independent agent.
-- SalesRef: immediate_sync = 0, shared agent.
DECLARE @pubprops TABLE (pub sysname, prop sysname, val nvarchar(400));
INSERT @pubprops VALUES
 (N'SalesPub', N'description', N'changed'), (N'SalesRef', N'description', N'changed'),
 (N'SalesPub', N'retention', N'100'), (N'SalesRef', N'retention', N'100'),
 (N'SalesPub', N'replicate_ddl', N'0'), (N'SalesRef', N'replicate_ddl', N'0'),
 (N'SalesPub', N'allow_pull', N'false'), (N'SalesRef', N'allow_pull', N'true'),
 (N'SalesPub', N'allow_push', N'false'),
 (N'SalesPub', N'allow_initialize_from_backup', N'true'), (N'SalesRef', N'allow_initialize_from_backup', N'true'),
 (N'SalesPub', N'allow_subscription_copy', N'true'), (N'SalesRef', N'allow_subscription_copy', N'true'),
 (N'SalesPub', N'allow_partition_switch', N'true'), (N'SalesRef', N'allow_partition_switch', N'true'),
 (N'SalesPub', N'replicate_partition_switch', N'true'),
 (N'SalesPub', N'allow_drop', N'true'), (N'SalesRef', N'allow_drop', N'true'),
 (N'SalesPub', N'status', N'inactive'), (N'SalesRef', N'status', N'inactive'),
 (N'SalesPub', N'sync_method', N'native'), (N'SalesRef', N'sync_method', N'concurrent'),
 (N'SalesPub', N'immediate_sync', N'false'), (N'SalesRef', N'immediate_sync', N'true'),
 (N'SalesPub', N'independent_agent', N'false'), (N'SalesRef', N'independent_agent', N'true'),
 (N'SalesPub', N'allow_anonymous', N'true'), (N'SalesRef', N'allow_anonymous', N'true'),
 (N'SalesPub', N'alt_snapshot_folder', N'/var/opt/mssql/data/ReplAlt'), (N'SalesRef', N'alt_snapshot_folder', N'/var/opt/mssql/data/ReplAlt'),
 (N'SalesPub', N'snapshot_in_defaultfolder', N'false'),
 (N'SalesPub', N'compress_snapshot', N'true'),
 (N'SalesPub', N'pre_snapshot_script', N'/var/opt/mssql/data/pre.sql'), (N'SalesRef', N'pre_snapshot_script', N'/var/opt/mssql/data/pre.sql'),
 (N'SalesPub', N'post_snapshot_script', N'/var/opt/mssql/data/post.sql'),
 (N'SalesPub', N'enabled_for_internet', N'true'),
 (N'SalesPub', N'enabled_for_het_sub', N'true'),
 (N'SalesPub', N'ftp_address', N'ftp.example.com');
INSERT @cases (label, stmt)
SELECT pub + N' publication ' + prop + N' = ' + val,
       REPLACE(REPLACE(REPLACE(@cp, N'{pub}', pub), N'{prop}', prop), N'{val}', val)
FROM @pubprops;

-- Article properties. Orders (SalesPub): no filter, custom commands.
-- Product (SalesRef). Customer (SalesPub): row and column filter.
DECLARE @artprops TABLE (pub sysname, art sysname, prop sysname, val nvarchar(400));
INSERT @artprops VALUES
 (N'SalesPub', N'Orders', N'description', N'changed'), (N'SalesRef', N'Product', N'description', N'changed'),
 (N'SalesPub', N'Orders', N'dest_table', N'Orders2'), (N'SalesRef', N'Product', N'dest_table', N'Product2'),
 (N'SalesPub', N'Orders', N'destination_owner', N'other'),
 (N'SalesPub', N'Orders', N'ins_cmd', N'CALL sp_MSins_dboOrders'), (N'SalesRef', N'Product', N'ins_cmd', N'SQL'),
 (N'SalesPub', N'Orders', N'upd_cmd', N'MCALL sp_MSupd_dboOrders'),
 (N'SalesPub', N'Orders', N'del_cmd', N'NONE'),
 (N'SalesPub', N'Orders', N'pre_creation_cmd', N'delete'), (N'SalesRef', N'Product', N'pre_creation_cmd', N'none'),
 (N'SalesPub', N'Orders', N'schema_option', N'0x000000000803509F'), (N'SalesRef', N'Product', N'schema_option', N'0x0000000000030077'),
 (N'SalesPub', N'Orders', N'status', N'include column names'), (N'SalesRef', N'Product', N'status', N'include column names'),
 (N'SalesPub', N'Orders', N'status', N'string literals'),
 (N'SalesPub', N'Orders', N'status', N'owner qualified'),
 (N'SalesPub', N'Orders', N'creation_script', N'/var/opt/mssql/data/create.sql'),
 (N'SalesPub', N'Orders', N'fire_triggers_on_snapshot', N'true'),
 (N'SalesPub', N'Orders', N'sync_object', N'vCustomerFR'),
 (N'SalesPub', N'Orders', N'type', N'logbased manualfilter'),
 (N'SalesPub', N'Customer', N'filter', N'FLTR_Customer'),
 (N'SalesPub', N'Customer', N'description', N'changed');
INSERT @cases (label, stmt)
SELECT pub + N'.' + art + N' article ' + prop + N' = ' + val,
       REPLACE(REPLACE(REPLACE(REPLACE(@ca, N'{pub}', pub), N'{art}', art), N'{prop}', prop), N'{val}', val)
FROM @artprops;

-- Filters on subscribed articles.
INSERT @cases (label, stmt) VALUES
 (N'SalesPub.Orders add row filter (sp_articlefilter)',
  N'EXEC sp_articlefilter @publication = N''SalesPub'', @article = N''Orders'', @filter_name = N''FLTR_Orders'', @filter_clause = N''Amount > 0'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (N'SalesPub.Customer change row filter clause (sp_articlefilter)',
  N'EXEC sp_articlefilter @publication = N''SalesPub'', @article = N''Customer'', @filter_name = N''FLTR_Customer'', @filter_clause = N''Country = ''''DE'''''', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (N'SalesPub.Customer drop row filter (sp_articlefilter NULL clause)',
  N'EXEC sp_articlefilter @publication = N''SalesPub'', @article = N''Customer'', @filter_name = N''FLTR_Customer'', @filter_clause = NULL, @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (N'SalesPub.Orders drop column (sp_articlecolumn)',
  N'EXEC sp_articlecolumn @publication = N''SalesPub'', @article = N''Orders'', @column = N''Amount'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (N'SalesPub.Customer add column back (sp_articlecolumn)',
  N'EXEC sp_articlecolumn @publication = N''SalesPub'', @article = N''Customer'', @column = N''Notes'', @operation = N''add'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r'),
 (N'SalesRef.Product drop column (sp_articlecolumn)',
  N'EXEC sp_articlecolumn @publication = N''SalesRef'', @article = N''Product'', @column = N''Label'', @operation = N''drop'', @force_invalidate_snapshot = @i, @force_reinit_subscription = @r');

DECLARE @flags TABLE (k int, i bit, r bit);
INSERT @flags VALUES (0, 0, 0), (1, 1, 0), (2, 0, 1), (3, 1, 1);
DECLARE @res TABLE (id int, k int, cell varchar(10), msg nvarchar(400));

DECLARE @id int, @stmt nvarchar(max), @k int, @i bit, @r bit;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT c.id, c.stmt, f.k, f.i, f.r FROM @cases AS c CROSS JOIN @flags AS f ORDER BY c.id, f.k;
OPEN c;
FETCH c INTO @id, @stmt, @k, @i, @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        EXEC sp_executesql @stmt, N'@i bit, @r bit', @i = @i, @r = @r;
        ROLLBACK;
        INSERT @res VALUES (@id, @k, 'ok', NULL);
    END TRY
    BEGIN CATCH
        DECLARE @e int = ERROR_NUMBER(), @m nvarchar(400) = LEFT(ERROR_MESSAGE(), 400);
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT @res VALUES (@id, @k, CONVERT(varchar(10), @e), CASE WHEN @e IN (20607, 20608) THEN NULL ELSE @m END);
    END CATCH;
    FETCH c INTO @id, @stmt, @k, @i, @r;
END;

SELECT c.id, c.label,
       MAX(CASE WHEN r.k = 0 THEN r.cell END) AS f00,
       MAX(CASE WHEN r.k = 1 THEN r.cell END) AS f10,
       MAX(CASE WHEN r.k = 2 THEN r.cell END) AS f01,
       MAX(CASE WHEN r.k = 3 THEN r.cell END) AS f11,
       MAX(r.msg) AS other_error
FROM @cases AS c JOIN @res AS r ON r.id = c.id
GROUP BY c.id, c.label
ORDER BY c.id;
GO
