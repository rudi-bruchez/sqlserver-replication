SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdategenhistory]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdategenhistory] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdategenhistory]
	@guidsrc [uniqueidentifier],
	@pubid [uniqueidentifier],
	@gen [bigint],
	@art_nick [int],
	@is_ssce_empty_sync [int],
	@publication_number [smallint],
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
/*
    ** Check to see if current publication has permission
    */
    declare @retcode int
    , @changecount int

    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
                RAISERROR (21723, 16, -1, 'sp_MSupdategenhistory')
                return 1
        end
        else
        begin
                RAISERROR (14126, 11, -1)
                return 1
        end
    end
    
    if (@guidsrc is null)
    begin
        RAISERROR(14043, 16, -1, '@guidsrc', 'sp_MSupdategenhistory')
        return (1)
    end
        
    if @art_nick = 0 set @art_nick = NULL
    set @changecount = 0
    
    begin tran
    save tran sp_MSupdategenhistory
    
    exec @retcode = sys.sp_MSget_gen_approx_changecount @gen, @changecount OUTPUT
        if @retcode <> 0 or @@error <> 0
                goto FAILURE

    -- If changecount is zero and this is a upload from ssce then delete the generation.
    -- This prevents uploading of empty generations.
    if @changecount = 0 and @is_ssce_empty_sync = 1
    begin
        delete from dbo.MSmerge_genhistory where generation = @gen
        commit
        return (0)
    end
    
    if @partition_id is null
    begin
        exec @retcode = sys.sp_MSmap_generation_to_partitionids @gen, @art_nick
        if @retcode <> 0 or @@error <> 0
                goto FAILURE
    end
    else
    begin
        insert into dbo.MSmerge_generation_partition_mappings with (rowlock)
            (publication_number, partition_id, generation, changecount)
                values (@publication_number, @partition_id, @gen, @changecount)
        if @@error <> 0
                goto FAILURE
    end
                        
    update dbo.MSmerge_genhistory with (rowlock)      
        set genstatus = 2, 
            art_nick = case when isnull(@art_nick,0) <> 0 then @art_nick else art_nick end, 
            coldate= getdate(),
            changecount = @changecount
    where generation = @gen -- and guidsrc = @guidsrc 
    if @@rowcount = 0
    begin
        declare @replnick binary(6)
        declare @nickbin binary(8)

        exec sys.sp_MSgetreplnick @replnick = @replnick out
        if @@ERROR<>0 goto FAILURE

        -- Append guard byte
        set @nickbin= @replnick + 0xFF

        set identity_insert dbo.MSmerge_genhistory on

        insert into dbo.MSmerge_genhistory with (rowlock)
            (guidsrc, genstatus, generation, art_nick, nicknames, coldate) 
            values (@guidsrc, 2, @gen, @art_nick, @nickbin , getdate())

        if @@ERROR<>0 goto FAILURE
            
        set identity_insert dbo.MSmerge_genhistory off

-- DEBUG        insert into MSmerge_debug (okay, artnick, generation_new, comment)
-- DEBUG            values (1, @art_nick, @gen, 'sp_MSupdategenhistory did an insert')
    end

    commit

    return (0)
    
FAILURE:
    rollback tran sp_MSupdategenhistory
    commit tran
    RAISERROR(25021, 16, -1, @gen)
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MSupdategenhistory] TO [public] AS [dbo]
GO
