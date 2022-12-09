SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdelrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdelrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdelrow]
	@rowguid [uniqueidentifier],
	@tablenick [int],
	@metadata_type [tinyint],
	@lineage_old [varbinary](311),
	@generation [bigint],
	@lineage_new [varbinary](311),
	@pubid [uniqueidentifier],
	@check_permission [int],
	@compatlevel [int],
	@articleisupdateable [bit],
	@publication_number [smallint],
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @match          int
    declare @new_metatype   tinyint
    declare @retcode        smallint
    declare @errcode        int
    declare @procname       sysname
    declare @objid          int
    declare @permissions    int
    declare @logical_record_parent_nickname     int
    declare @partition_options tinyint
        
    /* Parameter validation */
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSdelrow')
        return (0)
    end
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSdelrow')
        return (0)
    end
    
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 4
        
    if @check_permission =1
    begin
        select @objid=objid, @permissions= check_permissions from dbo.sysmergearticles 
            where nickname=@tablenick and (pubid is NULL or pubid=@pubid)
        if @objid is NULL
            return (0)

        exec @retcode = sys.sp_MSreplcheck_permission @objid = @objid, @type = 3, @permissions = @permissions
        if @retcode<>0 or @@ERROR<>0 return (4)
    end

    if 1 = @articleisupdateable and @lineage_new is not null
    begin
        if @compatlevel < 90
        begin
            set @lineage_new= {fn LINEAGE_80_TO_90(@lineage_new)}
            if @lineage_old is not null
                set @lineage_old= {fn LINEAGE_80_TO_90(@lineage_old)}
        end

        -- Are we just changing the type of a tombstone?
        -- This routine is only called for Upload; won't be type 5 (remove from partial) unless
        -- subscriber has a user delete and found an existing metadata type of 5 here.
        -- In that case, set delete type to 1 and update generation, reason text too.
        if (@metadata_type = 5)
        begin
            if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
            begin
                update dbo.MSmerge_tombstone set type = @metadata_type, generation = @generation, lineage = @lineage_new where
                  rowguid = @rowguid and tablenick = @tablenick
    -- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelrow: type 5->1')
                return 1
            end
        end
        -- Are we just changing the type of a tombstone?
        else if (@metadata_type = 6)
        begin
            if exists (select * from dbo.MSmerge_tombstone where rowguid = @rowguid and tablenick = @tablenick)
            begin
                update dbo.MSmerge_tombstone set type = @metadata_type,
                    generation = @generation, lineage = @lineage_new where
                    rowguid = @rowguid and tablenick = @tablenick
    -- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
    -- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelrow: new type 6')
                return 1
            end
        end
    end

    -- begin transaction and lock row that we plan to delete
    begin transaction
    save tran sp_MSdelrow

    declare @rowcount int

    select @procname = 'dbo.' + select_proc, @logical_record_parent_nickname = logical_record_parent_nickname,
        @partition_options = partition_options
    from dbo.sysmergepartitioninfoview
    where nickname = @tablenick 
    and pubid = @pubid
    
    if @partition_options = 2
    begin
        -- if this is a republisher of this article, and we are currently
        -- downloading from the top-level publisher, then pretend that this is 
        -- not a well-partitioned article. This is done such that the partition evaluation
        -- and setrowmetadata is done appropriately.
         if sys.fn_MSmerge_islocalpubid(@pubid) = 0 
            and exists (select * from dbo.sysmergearticles 
                            where nickname = @tablenick
                            and sys.fn_MSmerge_islocalpubid(pubid) = 1)
            select @partition_options = 0
    end
    
    /*
    exec @retcode = @procname @maxschemaguidforarticle = NULL, @type =8, @rowguid=@rowguid
    IF @@ERROR<>0 or @retcode<>0
    begin
        set @errcode= 0
        goto Failure
    end
    */


    if 1 = @articleisupdateable
    begin
        select @match = NULL

        if @metadata_type = 5
        begin
            set @new_metatype = 5
        end
        else if @metadata_type = 6
        begin
            set @new_metatype = 6
        end
        else
        begin
            /*
            -- call sp_MScheckmetadatamatch with @compatlevel=90, because sp_MSdelrow already
            -- did the map-up if needed
            exec @retcode=sys.sp_MScheckmetadatamatch 
                @metatype=@metadata_type, @rowguid=@rowguid, @tablenick=@tablenick, 
                @lineage=@lineage_old, @match=@match output, @compatlevel=90, @lineage_new=@lineage_new, 
                @new_type_contents=0
            IF @@ERROR<>0 or @retcode<>0
            begin
                set @errcode= 0
                goto Failure
            end
            */
            
            if @logical_record_parent_nickname = @tablenick
                select @match = 1

            set @new_metatype = 1
        end
    end
    else
    begin
        set @match= 1
    end
    
    if (@match = 1)
    begin
        -- select_proc makes a delete with @type = 5, despite its name. 
        -- we need not hold any lock on the row. Instead we will detect that if we could not delete the row
        -- we will raise an error
        exec @retcode = @procname 
                                                                  NULL, /* @maxschemaguidforarticle = NULL */
                                                                  11, -- @type
                                  @rowguid, -- @rowguid
                                  1, -- @enumentirerowmetadata not used
                                  0, -- @blob_cols_at_the_end not used
                                  '00000000-0000-0000-0000-000000000000', -- @logical_record_parent_rowguid not used
                                  0, -- @metadata_type
                                  NULL, -- @lineage_old
                                  @rowcount output
        if @retcode<>0
        begin
            set @errcode= 0
            goto Failure
        end
        
        if @rowcount <> 1
        begin
            set @errcode= 3
            goto Failure
        end
    end
    else if @match is NULL
    begin
        -- we need to do a metadatacheck in the delete proc
        exec @retcode = @procname 
                          NULL, /* @maxschemaguidforarticle = NULL */
                          11, -- @type
                          @rowguid, -- @rowguid
                          1, -- @enumentirerowmetadata not used
                          0, -- @blob_cols_at_the_end not used
                          '00000000-0000-0000-0000-000000000000', -- @logical_record_parent_rowguid not used
                          @metadata_type, -- @metadata_type
                          @lineage_old, -- @lineage_old
                          @rowcount output
        if @retcode<>0
        begin
            set @errcode= 0
            goto Failure
        end
        
        if @rowcount <> 1
        begin
            set @errcode= 2
            goto Failure
        end
    end
    if @@error<>0
    begin
        set @errcode= 0
        goto Failure
    end
        
    if 1 = @articleisupdateable and (@partition_options < 2 or @lineage_new is not null)
    begin
        -- call sp_MSsetrowmetadata with @compatlevel=90, because sp_MSdelrow
        -- already did the map-up if it is needed
        exec @retcode= sys.sp_MSsetrowmetadata 
             @tablenick, @rowguid, @generation, 
             @lineage_new, NULL, @new_metatype, NULL, 90, 
             @publication_number = @publication_number, @partition_id = @partition_id, 
             @partition_options = @partition_options
            
        IF @@ERROR<>0 or @retcode<>0
        begin
            set @errcode= 0
            goto Failure
        end
    end

    commit tran
-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        values (0, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, 1, getdate(), 'sp_MSdelrow: new type ' + cast(@new_metatype as nvarchar(2)))
    return(1)-- in sp_MSdelrow, 1=okay

Failure:
    rollback tran sp_MSdelrow
    commit tran
-- DEBUG    insert into MSmerge_debug (okay, artnick, rowguid, lineage_old, lineage_new, generation_new, type, successcode, twhen, comment)
-- DEBUG        values (1, @tablenick, @rowguid, @lineage_old, @lineage_new, @generation, @metadata_type, @errcode, getdate(), 'sp_MSdelrow: new type ' + cast(@new_metatype as nvarchar(2)))
    return(@errcode)
GO
GRANT EXECUTE ON [sys].[sp_MSdelrow] TO [public] AS [dbo]
GO
