SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IH_LR_GetCacheData]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IH_LR_GetCacheData] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IH_LR_GetCacheData]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin

	DECLARE @transactional int

	SET @transactional = 0

	-------- security check, db_owner
	declare @retcode int
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

    -- Begin serializable transaction
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
    BEGIN TRAN
    DECLARE @publisher_id int
    
    -- Determine the publisher ID
    select	@publisher_id = i.publisher_id
	from	IHpublishers i,
			MSreplservers s
	where	UPPER(s.srvname collate database_default) = UPPER(@publisher) collate database_default
	  and	i.publisher_id = s.srvid

	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END

	-- Retreive the cache publisher data
    select	i.publisher_id,
			d.login,
			sys.fn_repldecryptver4(d.password),
			i.vendor,
			CONVERT(varchar(255), i.publisher_guid),
			CONVERT(nvarchar(24), i.flush_request_time, 121),
			d.publisher_type
	from	IHpublishers i,
			MSreplservers s,
			msdb.dbo.MSdistpublishers d
	where	UPPER(s.srvname collate database_default) = UPPER(@publisher) collate database_default
	  and	i.publisher_id = s.srvid
	  and	UPPER(s.srvname collate database_default) = UPPER(d.name) collate database_default
	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END
	
	-- Retrieve the cache publication data
	select	i.name,
			i.repl_freq,
			i.status,
			i.sync_method,
			i.snapshot_jobid, 
			i.enabled_for_internet,
			i.immediate_sync_ready,
			i.allow_queued_tran, 
			i.allow_sync_tran,
			i.autogen_sync_procs,
			i.snapshot_in_defaultfolder, 
			i.alt_snapshot_folder,
			i.pre_snapshot_script,
			i.post_snapshot_script, 
			i.compress_snapshot,
			i.ftp_address,
			i.ftp_port,
			i.ftp_subdirectory, 
			i.ftp_login,
			sys.fn_repldecryptver4(i.ftp_password),
			i.allow_dts,
			i.allow_anonymous,
			i.ad_guidname, 
			i.backward_comp_level,
			m.publisher_id,
			m.publisher_db,
			m.publication_type, 
			m.independent_agent,
			m.immediate_sync,
			m.allow_push,
			m.allow_pull, 
			m.description,
			m.vendor_name,
			m.retention,
			m.allow_subscription_copy, 
			i.pubid
	from	IHpublications i,
			MSpublications m
	where	m.publisher_id = @publisher_id
	  and	i.pubid = m.publication_id
	  and	i.repl_freq = @transactional		

	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END

	-- Retrieve the cache primary key data 
	select	DISTINCT ihpcn.table_id,
			ihpcc.publishercolumn_id,
			ihpcc.indid 
	from	IHpublisherconstraints ihpcn,
			IHpublishercolumnconstraints ihpcc,
			IHpublishercolumns ihpco,
			IHarticles iha,
			IHpublications ip
	where	ihpcn.publisher_id				= @publisher_id
	  and	ihpcn.publisherconstraint_id	= ihpcc.publisherconstraint_id
	  and	ihpco.publishercolumn_id		= ihpcc.publishercolumn_id
	  and	ihpcn.type				= 'PRIMARYKEY'
	  and	ihpcn.table_id 	= iha.table_id	
	  and	iha.publication_id = ip.pubid
	  and	ip.repl_freq = @transactional
	order by ihpcc.indid

	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END

	-- Retrieve the cache column data 
	select	i.column_id,
			i.publishercolumn_id,
			i.name, 
			CASE i.mapped_length
				WHEN -1 THEN type_name(i.mapped_type) + N'(max)'
				ELSE type_name(i.mapped_type)
			END,
			i.mapped_length, 
			i.mapped_prec, i.mapped_scale,
			i.article_id,
			c.name,
			c.type,
			c.length,
			i.mapped_nullable 
	from	IHcolumns i,
			IHpublishercolumns c,
			MSarticles m,
			MSpublications l,
			IHarticles a,
			IHpublications ip
	where	c.publisher_id			= @publisher_id
	  and	i.article_id			= m.article_id
	  and	m.publication_id		= l.publication_id
	  and	i.article_id			= a.article_id
	  and	a.publication_id		= l.publication_id
	  and	m.publisher_id			= a.publisher_id
	  and	m.publisher_id			= l.publisher_id
	  and	i.publishercolumn_id	= c.publishercolumn_id
	  and	m.publication_id = ip.pubid
	  and	ip.repl_freq = @transactional
	order by i.article_id, i.column_ordinal

	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END

	-- Retrieve the cache article data 
	select	a.article_id,
			a.name,
			a.table_id, 
			del_cmd,
			filter,
			filter_clause,
			ins_cmd,
			pre_creation_cmd,
			a.status,
			type,
			upd_cmd,
			dest_owner,
			dest_table, 
			a.publication_id,
			p.owner,
			p.name,
			a.publisher_status,
			a.instance_id
	from	IHarticles a,
			IHpublishertables p, 
			MSarticles m,
			MSpublications l,
			IHpublications ip
	where	a.publisher_id		= @publisher_id
	  and	a.publisher_id		= p.publisher_id
	  and	a.table_id			= p.table_id
	  and	a.publication_id	= l.publication_id
	  and	a.article_id		= m.article_id
	  and	a.publication_id	= m.publication_id
	  and	a.publisher_id		= m.publisher_id
	  and	a.publisher_id		= l.publisher_id
	  and	m.publication_id 	= ip.pubid
	  and	ip.repl_freq		= @transactional
	if @@error<>0
	BEGIN
		COMMIT TRAN
		SET TRANSACTION ISOLATION LEVEL READ COMMITTED
        return(1)
	END

	COMMIT TRAN
	SET TRANSACTION ISOLATION LEVEL READ COMMITTED
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_IH_LR_GetCacheData] TO [public] AS [dbo]
GO
