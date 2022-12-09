SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddinitialarticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddinitialarticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddinitialarticle]
	@article [sysname],
	@artid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@nickname [int],
	@column_tracking [int],
	@status [int],
	@pre_creation_command [int],
	@resolver_clsid [nvarchar](255),
	@insert_proc [nvarchar](255),
	@update_proc [nvarchar](255),
	@select_proc [nvarchar](255),
	@destination_object [sysname],
	@missing_count [int],
	@missing_cols [varbinary](128),
	@article_resolver [nvarchar](255),
	@resolver_info [nvarchar](517),
	@filter_clause [nvarchar](2000),
	@excluded_count [int],
	@excluded_cols [varbinary](128),
	@destination_owner [sysname],
	@identity_support [int],
	@verify_resolver_signature [int],
	@fast_multicol_updateproc [bit],
	@published_in_tran_pub [bit],
	@logical_record_level_conflict_detection [bit],
	@logical_record_level_conflict_resolution [bit],
	@partition_options [tinyint],
	@processing_order [int],
	@upload_options [tinyint],
	@delete_tracking [bit],
	@compensate_for_errors [bit],
	@pub_identity_range [bigint],
	@identity_range [bigint],
	@threshold [int],
	@stream_blob_columns [bit],
	@preserve_rowguidcol [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @objid                              int
    declare @sub_missing_cols   binary(128)
    declare @retcode                    int
    declare @upload_options_previous tinyint
    declare @delete_tracking_previous  bit
    declare @stream_blob_columns_previous  bit    
    declare @compensate_for_errors_previous bit
    declare @preserve_rowguidcol_previous bit
    declare @qualified_name nvarchar(270)


    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    if (@artid is NULL)
    BEGIN
        RAISERROR (14057, 16, -1)
        RETURN (1)
    END

    -- If this is a no-sync subscription then the article should exist before
    -- we can create entry in sysmergearticles.

    if exists (select * from dbo.sysmergesubscriptions
                where upper(subscriber_server collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS)
                    and pubid = @pubid and db_name = DB_NAME() and sync_type = 2)
    begin

    if @destination_owner IS NULL
    begin
            select @qualified_name = quotename(@destination_object)
    end
    else
    begin
            select @qualified_name = quotename(@destination_owner) + '.' + quotename(@destination_object)
    end

        select @objid = object_id(@qualified_name)
        
        if @objid IS NULL
        begin 
            raiserror(21078, 16, -1, @destination_object)
            RETURN (1)
         end
    end
    
   -- Make sure the article does not already exist in a lightweight subscription.
    if exists (select top 1 artid from dbo.sysmergearticles 
                    where nickname=@nickname and lightweight=1)
    begin
        raiserror(21526,16,1, @article)
        return 1
    end

    /*
    ** The columns that do not belong to the partition at subscriber side are nothing but
    ** missing columns to the subscriber side - it just does not have them !
    ** For the same reason, the excluded ones from publisher does not mean anything to
    ** subscriber, which does not exclude anything for itself. We just reset to 0
    */
    select @missing_count = @missing_count + @excluded_count
    exec @retcode= sys.sp_ORbitmap @missing_cols, @excluded_cols, @sub_missing_cols OUTPUT
    if @@error<>0 or @retcode<>0 return(1)
    
    if (@resolver_clsid='')  select @resolver_clsid = NULL
    
    if (@filter_clause='') set @filter_clause = NULL
    
    -- If that article is already part of another publication, reuse its "upload_options" property.
    set @upload_options_previous= (select top 1 upload_options 
                                    from dbo.sysmergearticles
                                    where artid = @artid)
    if @upload_options_previous is not null
        set @upload_options= @upload_options_previous


        -- If that article is already of another publication, reuse its "delete_tracking" property.
    -- 1 is default so look for 0.
    set @delete_tracking_previous= 1
    select @delete_tracking_previous= delete_tracking from dbo.sysmergearticles
                                                                        where artid = @artid and
                                                                                  delete_tracking = 0
    if 0 = @delete_tracking_previous
        set @delete_tracking=0

        -- If that article is already of another publication, reuse its "stream_blob_columns" property.
    -- 1 is default so look for 0.
    set @stream_blob_columns_previous= 1
    select @stream_blob_columns_previous= stream_blob_columns from dbo.sysmergearticles
                                                                        where artid = @artid and
                                                                                  stream_blob_columns = 0
    if 0 = @stream_blob_columns_previous
        set @stream_blob_columns=0

    -- If that article is already part of another publication, reuse its "compensate_for_errors" property.
    set @compensate_for_errors_previous= (select top 1 compensate_for_errors 
                                                                                        from dbo.sysmergearticles
                                                                                where artid = @artid)
    if @compensate_for_errors_previous is not null
        set @compensate_for_errors= @compensate_for_errors_previous
   
    -- If that article is already part of another publication, reuse its "preserve_rowguidcol" property.
    set @preserve_rowguidcol_previous= (select top 1 preserve_rowguidcol 
                                               from dbo.sysmergearticles
                                           where artid = @artid)
    if @preserve_rowguidcol_previous is not null
        set @preserve_rowguidcol= @preserve_rowguidcol_previous
               
    /*
    ** Populate the local copy of dbo.sysmergearticles
    */
    if exists (select * from dbo.sysmergearticles where artid = @artid and pubid = @pubid )
        begin
        
        -- updating an existing entry to become not well-partitioned is never a problem. updating to make it
        -- well-partitioned can only be allowed when this is the only entry.
        --if @well_partitioned = 1 and (select count(*) from dbo.sysmergepartitioninfo where artid = @artid) > 1
        --begin
        --      raiserror(21535, 16, -1, @article)
        --      return 1
        --end   

            update dbo.sysmergearticles 
                set name = @article,
                    pre_creation_command = pre_creation_command,
                    nickname = @nickname,
                    column_tracking = @column_tracking,
                    status  = @status,
                    resolver_clsid = @resolver_clsid,
                    insert_proc = @insert_proc,
                    update_proc =  @update_proc,
                    select_proc = @select_proc,
                    destination_object = @destination_object,
                    destination_owner = @destination_owner,
                    missing_col_count = @missing_count,
                    missing_cols = @sub_missing_cols,
                    article_resolver = @article_resolver,
                    resolver_info = @resolver_info,
                    subset_filterclause = @filter_clause,
                    excluded_col_count = 0,
                    excluded_cols = 0x00,
                    identity_support=@identity_support,
                    verify_resolver_signature = @verify_resolver_signature,
                    fast_multicol_updateproc = @fast_multicol_updateproc,
                    processing_order = @processing_order,
                    upload_options= @upload_options,
                    delete_tracking=@delete_tracking,
                    published_in_tran_pub = @published_in_tran_pub,
                    compensate_for_errors= @compensate_for_errors,
                    pub_range = @pub_identity_range,
                    range = @identity_range,
                    threshold = @threshold,
                    stream_blob_columns = @stream_blob_columns,
                    preserve_rowguidcol = @preserve_rowguidcol

                where artid = @artid and pubid = @pubid
                
                update dbo.sysmergepartitioninfo
                set logical_record_level_conflict_detection = @logical_record_level_conflict_detection,
                        logical_record_level_conflict_resolution = @logical_record_level_conflict_resolution,
                        partition_options = @partition_options
                where artid = @artid and pubid = @pubid

        -- set up deleted col info
        declare @deleted_cols varbinary(128)
        execute sp_MSfillup_deleted_cols @objid, @deleted_cols output
        update dbo.sysmergearticles set deleted_cols=@deleted_cols 
                where artid = @artid and pubid=@pubid

        end
    else
        begin
            --if @well_partitioned = 1 and exists (select * from dbo.sysmergepartitioninfo where artid = @artid)
            --begin
            --  raiserror(21535, 16, -1, @article)
            --  return 1
            --end
            --else if @well_partitioned = 0 and exists 
                        --(select * from dbo.sysmergepartitioninfo where artid = @artid and well_partitioned = 1)
            --begin
                --raiserror(21536, 16, -1, @article)
                --return 1
            --end

            select @objid = 0
            insert into dbo.sysmergearticles (name, type, objid, sync_objid, artid, pre_creation_command, pubid, 
                nickname, column_tracking, status, resolver_clsid, destination_owner,
                insert_proc, update_proc, select_proc, destination_object, missing_col_count, missing_cols, 
                article_resolver, resolver_info, subset_filterclause, excluded_col_count, excluded_cols, identity_support,
                verify_resolver_signature, fast_multicol_updateproc, processing_order, upload_options, published_in_tran_pub,
                delete_tracking, compensate_for_errors, pub_range, range, threshold, stream_blob_columns, preserve_rowguidcol)
            values (@article, 0x0a, @objid, @objid, @artid, @pre_creation_command, @pubid, 
                @nickname, @column_tracking, @status, @resolver_clsid, @destination_owner,
                @insert_proc, @update_proc, @select_proc, @destination_object, @missing_count, @sub_missing_cols, 
                @article_resolver, @resolver_info, @filter_clause, 0, 0x00, @identity_support, @verify_resolver_signature, 
                @fast_multicol_updateproc, @processing_order, @upload_options, @published_in_tran_pub,
                @delete_tracking, @compensate_for_errors, @pub_identity_range, @identity_range, @threshold, @stream_blob_columns, @preserve_rowguidcol)
                
            insert into dbo.sysmergepartitioninfo (artid, pubid, logical_record_level_conflict_detection, logical_record_level_conflict_resolution, partition_options) 
                values (@artid, @pubid, @logical_record_level_conflict_detection, @logical_record_level_conflict_resolution, @partition_options)

        end
    IF @@ERROR <> 0
    BEGIN
        RAISERROR (14057, 16, -1)
        RETURN (1)
    END

    -- Make sure Filters and Identity Ranges do not exist if reapplying article after failed attempt
    delete from dbo.sysmergesubsetfilters where artid = @artid and pubid = @pubid
    delete from dbo.MSmerge_identity_range where is_pub_range = 0 and artid = @artid and subid in
        ( select subid from dbo.sysmergesubscriptions where pubid = @pubid and subid <> pubid and sys.fn_MSmerge_islocalsubid(subid) = 1 )

    RETURN 0
GO
GRANT EXECUTE ON [sys].[sp_MSaddinitialarticle] TO [public] AS [dbo]
GO
