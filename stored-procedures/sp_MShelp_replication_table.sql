SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_replication_table]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_replication_table] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_replication_table]
	@table_name [sysname],
	@table_owner [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

declare @objid int
declare @retcode int
declare @OPT_ENABLED_FOR_P2P int

select @OPT_ENABLED_FOR_P2P = 0x1

--
-- Security Check
--
exec @retcode = sys.sp_MSreplcheck_publish
if @@ERROR <> 0 or @retcode <> 0
	return(1)

if @table_name is not null
begin
	if @table_owner is NULL
		select @table_owner = schema_name()
	declare @qualified_table_name   nvarchar(4000)
	select @qualified_table_name = QUOTENAME(@table_owner) + '.' + QUOTENAME(@table_name)
	select @objid = object_id(@qualified_table_name)
	if @objid is null
	begin
		RAISERROR (14027, 11, -1, @qualified_table_name)
		return(1)
	end
end

create table #merge_objects (objid int primary key)

create table #tran_objects (objid int, is_queued bit default 0, is_peertopeer bit default 0)

if object_id('sysmergearticles') is not null
	insert into #merge_objects select distinct objid from dbo.sysmergearticles where 
		objid = @objid or @objid is null

if object_id('sysarticles') is not null
	insert into #tran_objects 
		select distinct sa.objid,
				isnull(sp.allow_queued_tran, 0),
				isnull((sp.options & @OPT_ENABLED_FOR_P2P), 0)
			from syspublications sp 
				join sysarticles sa
					on sp.pubid = sa.pubid
			where sa.objid = @objid
				or @objid is null
					
select  'table name' = o.name, 
		'table owner' = schema_name(o.schema_id), 
		'ID' = o.object_id, 
		'Category' = case when 
			(ObjectProperty(o.object_id, 'TableHasPrimaryKey') = 1)
			then 512 else 0 end,   
		'HasGuidColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and
				type_name(c.system_type_id) = 'uniqueidentifier')
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasTimeStampColumn' = ObjectProperty(o.object_id, 'TableHasTimestamp'),
		'HasRowVersionColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and 
				name = N'msrepl_tran_version')
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasIdentityColumn' = 
			case when ObjectProperty(o.object_id, 'TableHasIdentity') = 1
						and not exists (select * from sys.columns c 
							where c.object_id = o.object_id
							and type_name(c.system_type_id) = 'tinyint'
							and is_identity = 1
							) then 1 else 0 end,
		'HasSQLVariantColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and
				type_name(c.system_type_id) = 'sql_variant') 
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasBigIntColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and
				type_name(c.system_type_id) = 'bigint')
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasBigIntIdentityColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and
				ColumnProperty(o.object_id, c.name, 'IsIdentity') = 1 and
				type_name(c.system_type_id) = 'bigint')
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'MergePublished' = case when exists (select * from #merge_objects m where
			m.objid = o.object_id)
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'QueuedTranPublished' = case when exists (select *
													from #tran_objects tobj 
													where tobj.objid = o.object_id
														and isnull(is_queued, 0) = 1)
									then cast(1 as bit)
									  else cast(0 as bit)
								end,
		'HasIdentityNotForReplColumn' = case when 
				exists (select * from sys.columns c where c.object_id = o.object_id and 
					ColumnProperty(o.object_id, c.name, 'IsIdNotForRepl') = 1)
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasImprecisePkColumn' = sys.fn_fcomputedpkimprecise(o.object_id),
		'PeerToPeerPublished' = case when exists (select *
													from #tran_objects tobj 
													where tobj.objid = o.object_id
														and isnull(is_peertopeer, 0) = 1)
									then cast(1 as bit)
									  else cast(0 as bit)
								end,
		'HasHierarchyIdColumn' = case when
				exists (select * 
						  from sys.columns sc
					inner join sys.types st
							on sc.object_id = o.object_id
						   and sc.system_type_id = st.system_type_id
						   and sc.user_type_id = st.user_type_id
						 where st.name = N'hierarchyid'
						   and schema_name(st.schema_id) = N'sys')
									then cast(1 as bit)
									else cast(0 as bit)
								end,
		'HasSparseColumn' = case when
				exists (select * from sys.columns c where c.object_id = o.object_id and c.is_sparse = 1)
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'HasColumnSetColumn' = case when
				exists (select * from sys.columns c where c.object_id = o.object_id and c.is_column_set = 1)
			then cast(1 as bit) 
			else cast(0 as bit)
			end,
		'IsFileTable' = (select is_filetable from sys.tables t where t.object_id = o.object_id)
		from sys.objects o where o.type = 'U' and 
			ObjectProperty(o.object_id, 'IsMSShipped') = 0 and
			--in cdc enabled db, repl ui should filter out objects owned by cdc schema
		   ((o.schema_id  <> SCHEMA_ID('cdc')) or (db_id() in (select database_id from sys.databases where is_cdc_enabled = 0))) and 
			(o.object_id = @objid or @objid is null)
			order by 1, 2
		
drop table #merge_objects
drop table #tran_objects
GO
GRANT EXECUTE ON [sys].[sp_MShelp_replication_table] TO [public] AS [dbo]
GO
