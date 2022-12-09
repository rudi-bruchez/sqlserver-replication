SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_mergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_mergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_mergearticle]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@property [sysname],
	@value [nvarchar](2000),
	@value_numeric [int]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @artidstr            nvarchar(38)
    declare @pubidstr            nvarchar(38)
    declare @value_str            nvarchar(270)
    declare @artnick            int
    declare @retcode            int
    declare @schemaversion        int 
    declare @schemaguid            uniqueidentifier
    declare @schematype            int
    declare @schematext            nvarchar(4000)
    declare @publication        sysname
    declare @publisher             sysname
    declare @subscriber            sysname
    declare @subscriber_db        sysname
    declare @pubid_iter            uniqueidentifier
    declare @subid_iter         uniqueidentifier
    declare @islightweight        bit
    declare @publishes_to_any    bit
    declare @publishes_to_non_global bit
    declare @qualified_name nvarchar(520)
    declare @objid int
    declare @SCHEMA_TYPE_COMPENSATE_FOR_ERRORS int
    declare @SCHEMA_TYPE_UPLOADOPTIONS int
    declare @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM int
    declare @previoustinyintvalue tinyint
    declare @upload_first nvarchar(10)
    
    -- Security check
    if 1 <> is_member('db_owner')
    begin    
        RAISERROR (15247, 11, -1)
        return (1)
    end

    set @SCHEMA_TYPE_COMPENSATE_FOR_ERRORS= 24
    set @SCHEMA_TYPE_UPLOADOPTIONS= 26
    set @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM = 303

    /*
    ** Parameter Check:     @property.
    ** Check to make sure that @property is a valid property
    */
    if @property IS NULL OR LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT in 
                                                    ('partition_options',
                                                     'processing_order',
                                                     'published_in_tran_pub',
                                                     'compensate_for_errors',
                                                     'subscriber_upload_options',
                                                     'stream_blob_columns')
    begin
        raiserror (21259, 16, -1, @property)
        return (1)
    end

     select top 1 @islightweight= lightweight 
         from dbo.sysmergearticles where artid=@artid
        
    if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'partition_options'
    begin
        if @value_numeric NOT IN (0, 1, 2, 3)
        BEGIN
            RAISERROR (22526, 16, -1, '@partition_options')
            return 1
        END

        /*
        ** Update the syssubsetdefintions table with the new column tracking.
        */
        update dbo.sysmergepartitioninfo set partition_options = @value_numeric
            where artid = @artid and pubid = @pubid
        if @@ERROR <> 0 return 1

        if @value_numeric in (2, 3)
        begin
            if 1=@islightweight
            begin
                update dbo.sysmergearticles set well_partitioned_lightweight= 1 
                    where artid=@artid and pubid=@pubid
                if @@ERROR <> 0 return 1
            end
            
            select top 1 @publication= name
                            from dbo.sysmergepublications
                            where pubid= @pubid
            exec @retcode = sys.sp_MSvalidate_wellpartitioned_articles @publication
            if @@error <> 0 or @retcode <> 0 return 1
        end
        else
        begin
            if 1=@islightweight
            begin
                update dbo.sysmergearticles set well_partitioned_lightweight= 0 
                    where artid=@artid and pubid=@pubid
                if @@ERROR <> 0 return 1
            end
        end
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'processing_order'
    begin

        declare @processing_order int
        select @processing_order = convert(int, @value) 
        
        update dbo.sysmergearticles set processing_order = @processing_order
        where artid = @artid and pubid = @pubid
        if @@error<>0
            return 1
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'published_in_tran_pub'
    begin
        declare @published_in_tran_pub_bit bit
        
        /* Check to make sure that we have a true/false. */
        if lower(@value collate SQL_Latin1_General_CP1_CS_AS) not in ('true', 'false')
        begin
            raiserror (14148, 16, -1, 'published_in_tran_pub')
            return 1
        end

        /* Determine the bit value. */
        if lower(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        begin
            set @published_in_tran_pub_bit = 1
        end
        else
            set @published_in_tran_pub_bit = 0
    
        /* Update the subscription with the new 'published_in_tran_pub' value. */
        update dbo.sysmergearticles set published_in_tran_pub = @published_in_tran_pub_bit
            where artid = @artid and pubid = @pubid
        if @@error <> 0
        begin
            raiserror (14053, 16, -1)
            return 1
        end
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'compensate_for_errors'
    begin
        update dbo.sysmergearticles set compensate_for_errors = @value_numeric
            where artid = @artid
        if @@error<>0 return 1

        -- Insert a schemachange for all publications the article belongs to.
        set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                        publisher_db = db_name() and
                                      pubid in (select pubid from dbo.sysmergearticles 
                                                    where artid=@artid)
                                order by pubid asc)
        
        while @pubid_iter is not null
        begin
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                set @schemaversion = 1
            set @schemaguid = newid()
            
            set @schematype = @SCHEMA_TYPE_COMPENSATE_FOR_ERRORS
            select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid=''' + convert(nchar(36), @pubid_iter) + ''', @artid=''' + convert(nchar(36), @artid) + ''', @property=''compensate_for_errors'', @value_numeric=''' + cast(@value_numeric as nchar(1)) + ''''
                                     
            exec @retcode = sys.sp_MSinsertschemachange @pubid_iter, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR <> 0 OR @retcode <> 0 return 1
                
            set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                    where pubid > @pubid_iter and
                                          upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                              publisher_db = db_name() and
                                            pubid in (select pubid from dbo.sysmergearticles 
                                                        where artid=@artid)
                                    order by pubid asc)
        end
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'stream_blob_columns'
    begin
        update dbo.sysmergearticles set stream_blob_columns = @value_numeric
            where artid = @artid
        if @@error<>0 return 1

        -- Insert a schemachange for all publications the article belongs to.
        set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                        publisher_db = db_name() and
                                      pubid in (select pubid from dbo.sysmergearticles 
                                                    where artid=@artid)
                                order by pubid asc)
        
        while @pubid_iter is not null
        begin
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                set @schemaversion = 1
            set @schemaguid = newid()
            
            set @schematype = @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM
            
            select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid=''' + convert(nchar(36), @pubid_iter) + ''', @artid=''' + convert(nchar(36), @artid) + ''', @property=''stream_blob_columns'', @value_numeric=''' + cast(@value_numeric as nchar(1)) + ''''
                                     
            exec @retcode = sys.sp_MSinsertschemachange @pubid_iter, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR <> 0 OR @retcode <> 0 return 1
                
            set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                    where pubid > @pubid_iter and
                                          upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                              publisher_db = db_name() and
                                            pubid in (select pubid from dbo.sysmergearticles 
                                                        where artid=@artid)
                                    order by pubid asc)
        end
    end
    else if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'subscriber_upload_options'
    begin
        set @publishes_to_any= 0
        set @publishes_to_non_global= 0
    
        select top 1 @artnick= nickname, @previoustinyintvalue = upload_options from dbo.sysmergearticles where artid = @artid
        if @@error<>0 return 1
        
        update dbo.sysmergearticles set upload_options= @value_numeric where artid = @artid
        
        -- Propagate the schemachange if this replica has its own publications, and the article
        -- belongs to them.
        set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications where
                            upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername()) and
                            publisher_db = db_name() and
                            pubid in (select pubid from dbo.sysmergearticles where artid=@artid)
                            order by pubid asc)
                
        while @pubid_iter is not null
        begin
            set @publishes_to_any= 1
            set @schematext= 'exec sp_MSchange_mergearticle @pubid=''' + cast(@pubid_iter as nchar(36)) + ''', @artid=''' + cast(@artid as nchar(36)) + ''', @property=''subscriber_upload_options'', @value_numeric=' + cast(@value_numeric as nchar(1))
            select @schemaversion= isnull(max(schemaversion), 0) + 1 from dbo.sysmergeschemachange
            set @schemaguid= newid()
            set @schematype= @SCHEMA_TYPE_UPLOADOPTIONS
    
            exec @retcode=sys.sp_MSinsertschemachange @pubid_iter, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR<>0 or @retcode<>0 return 1
    
            set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications where
                                pubid > @pubid_iter and
                                upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername()) and
                                publisher_db = db_name() and
                                pubid in (select pubid from dbo.sysmergearticles where artid=@artid)
                                order by pubid asc)
        end
        
        if 1=@publishes_to_any
        begin
            if exists (select * from dbo.sysmergesubscriptions where 
                subscriber_type<>1 and
                pubid in (select pubid from dbo.sysmergearticles where artid=@artid) and
                pubid in (select pubid from dbo.sysmergepublications where 
                            upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername()) and
                            publisher_db = db_name()))
            begin
                set @publishes_to_non_global= 1
            end
        end

        if 1=@publishes_to_non_global
        begin
            if 0=@value_numeric
            begin
                -- Non-global subscribers subscribe to this replica for publications
                -- that contain the article which becomes updateable: 
                -- Set the generation of all rows to 0, so that data and metadata will be resent to the
                -- non-global subscribers. The data will also be resent to other replicas, but this is
                -- still better than having to reinitialize the non-global subscribers.
                
                update dbo.MSmerge_tombstone set generation= 0 where tablenick = @artnick
                update dbo.MSmerge_contents set generation= 0 where tablenick = @artnick
                update dbo.MSmerge_past_partition_mappings set generation= 0 where tablenick = @artnick
            end
            else if ((@previoustinyintvalue = 0) and (@value_numeric <> 0))
            begin
                -- If there are non-global subscriptions to publications that contain this article
                -- that is changing its upload_options, they need to be reinitialized,
                -- because the subscribers might have data that are not uploaded yet. This data
                -- may no longer get uploaded after the change to upload_options, which would cause
                -- non-convergence.

                set @subid_iter= (select top 1 subid from dbo.sysmergesubscriptions 
                                    where subscriber_type<>1 and
                                          pubid in (select pubid from dbo.sysmergearticles where artid=@artid) and
                                          (upper(subscriber_server collate SQL_Latin1_General_CP1_CS_AS) <> upper(publishingservername()) or
                                           db_name <> db_name())
                                    order by subid asc)

                while @subid_iter is not null
                begin
                    select @subscriber= subscriber_server, @subscriber_db= db_name
                        from dbo.sysmergesubscriptions
                        where subid=@subid_iter

                    select top 1 
                            @publication= name,
                            @upload_first = case automatic_reinitialization_policy
                                                when 1 then 'true'
                                                else 'false'
                                            end
                        from dbo.sysmergepublications
                        where pubid= (select pubid from dbo.sysmergesubscriptions
                                        where subid=@subid_iter)

                    exec @retcode= sys.sp_reinitmergesubscription
                                            @publication=@publication,
                                            @subscriber= @subscriber,
                                            @subscriber_db= @subscriber_db,
                                            @upload_first= @upload_first

                    if @@error<>0 or @retcode<>0 return 1
                    
                    set @subid_iter= (select top 1 subid from dbo.sysmergesubscriptions 
                                        where subid>@subid_iter and
                                              subscriber_type<>1 and
                                              pubid in (select pubid from dbo.sysmergearticles where artid=@artid) and
                                              (upper(subscriber_server collate SQL_Latin1_General_CP1_CS_AS) <> upper(publishingservername()) or
                                               db_name <> db_name())
                                        order by subid asc)
                end
            end
        end
        else if exists (select * from dbo.sysmergesubscriptions where
                    subscriber_type<>1 and
                    pubid in (select pubid from dbo.sysmergearticles where artid=@artid) and
                    upper(subscriber_server collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername()) and
                    db_name = db_name())
        begin
            -- The replica is a non-global subscriber to publications that contain this article.
    
            if 0 <> @value_numeric
            begin
                select top 1 @artnick= nickname
                    from dbo.sysmergearticles where artid=@artid
                
                -- Delete row metadata.
                if 1=@islightweight
                begin
                    delete from dbo.MSmerge_rowtrack where tablenick = @artnick
                end
                else
                begin
                    delete from dbo.MSmerge_tombstone where tablenick = @artnick
                    delete from dbo.MSmerge_contents where tablenick = @artnick
                    delete from dbo.MSmerge_past_partition_mappings where tablenick = @artnick
                end
            end
    
            -- Recreate triggers and procs for all publications the replica subscribed to, and which
            -- contain this article.
    

            select top 1 @objid= objid from dbo.sysmergearticles where artid=@artid
    
            exec @retcode= sys.sp_MSget_qualified_name
                                    @object_id= @objid,                      
                                    @qualified_name= @qualified_name output
            if @@error<>0 or @retcode<>0 return 1
    
            set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications where
                                pubid in (select pubid from dbo.sysmergearticles where artid=@artid)
                                order by pubid asc)
                    
            while @pubid_iter is not null
            begin
                exec @retcode= sys.sp_MSResetTriggerProcs
                                @qual_source_object= @qualified_name,
                                @pubid= @pubid_iter
                if @@error<>0 or @retcode<>0 return 1
                
                set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications where
                                    pubid > @pubid_iter and
                                    pubid in (select pubid from dbo.sysmergearticles where artid=@artid)
                                    order by pubid asc)
            end
        end -- upload_options
    end
    
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSchange_mergearticle] TO [public] AS [dbo]
GO
