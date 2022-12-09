SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addqueued_artinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addqueued_artinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addqueued_artinfo]
	@artid [int],
	@article [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dest_table [sysname],
	@owner [sysname],
	@cft_table [sysname],
	@columns [binary](32)
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare  @agent_id int
                ,@update_mode int
                ,@retcode int
                ,@thisspname sysname

    select @thisspname = N'sp_addqueued_artinfo'
    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- Create MSsubscription_agents/MSsubscription_articles if necessary
    -- this could be needed for manual synchronization case
    --
    if object_id(N'dbo.MSsubscription_agents') is null
        or object_id(N'dbo.MSsubscription_articles') is null
        or object_id(N'dbo.MSsubscription_articlecolumns') is null
    begin
        exec @retcode = sys.sp_MScreate_sub_tables_internal
                    @tran_sub_table = 1,
                    @property_table = 1,
                    @sqlqueue_table = 1,
                    @subscription_articles_table = 1
        if  (@@error != 0 or @retcode != 0)
            return 1
    end
    --
    -- insert the row for the given article
    --
    select @agent_id = id, @update_mode = update_mode
    from dbo.MSsubscription_agents 
    where UPPER(publisher) = UPPER(@publisher) and 
        publisher_db = @publisher_db and 
        publication = @publication 

    if (@agent_id IS NULL)
    begin
        raiserror(21758, 16, 1, @publisher, @publisher_db, @publication)
        return (1)
    end
    --
    -- If the subscription is read only or immediate, no need to article info.
    --
    if @update_mode in (0,1)
        return 0
    --
    -- If MSMQ Queued mode - check if the subscriber is compliant for MSMQ 2.0
    --
    if (@update_mode in (2,3))
    begin
        if ((platform() & 0x1) != 0x1)
        begin
            --
            -- Win 9X platform
            --
            raiserror(21334, 16, 1, '2.0')
            return (1)
        end
        --
        -- Now we use xp_MSver to detect NT OS version
        -- MSMQ subscription only allowed for platforms that support MSMQ 2.0
        -- version 5.0.2195 or higher
        --
        create table #tosversion ( propid int, propname sysname collate database_default, value int, charvalue nvarchar(255) collate database_default)
        insert into #tosversion (propid, propname, value, charvalue)
        exec master.dbo.xp_msver N'WindowsVersion'

        declare @vervalue int
                    ,@lobyte tinyint
                    ,@hibyte tinyint
                    ,@loword smallint
                    ,@hiword smallint

        --
        -- low order byte of low order word = OSmajor, high order byte of low order word = OSminor
        -- high order word = OSbuild
        --
        select @vervalue = value from #tosversion where propname = N'WindowsVersion'
        select @loword = (@vervalue & 0xffff)
                ,@hiword = (@vervalue / 0x10000) & 0xffff
        select @lobyte = @loword & 0xff
                ,@hibyte = (@loword / 100) & 0xff
        drop table #tosversion
        --
        -- check for OS major version
        --
        if (@lobyte < 5)
        begin
            raiserror(21334, 16, 2, '2.0')
            return (1)
        end
        --
        -- check for OS build version
        --
        if (@lobyte = 5 and @hiword < 2195)
        begin
            raiserror(21334, 16, 3, '2.0')
            return (1)
        end
    end
    --
    -- Check for owner - use current user for NULL value
    --
    if (@owner IS NULL or lower(@owner) = N'null' collate database_default)
        select @owner = schema_name()
    --
    -- refresh entry in MSsubscription_articles
    --
    if exists (select * from dbo.MSsubscription_articles where agent_id = @agent_id and artid = @artid)
        delete dbo.MSsubscription_articles where agent_id = @agent_id and artid = @artid
    insert into dbo.MSsubscription_articles(agent_id, artid, article, dest_table, owner, cft_table)
        values (@agent_id, @artid, @article, @dest_table, @owner, @cft_table)
    IF (@@ERROR != 0)
    begin
        raiserror(21499, 16, 1, @thisspname, 'populate', 'MSsubscription_articles', @@error)
        return (1)
    end
    --
    -- If 80 publisher issued this call - then populate MSsubscription_articlecolumns
    --
    if (@columns is not null)
    begin
        if exists (select * from dbo.MSsubscription_articlecolumns where agent_id = @agent_id and artid = @artid)
            delete dbo.MSsubscription_articlecolumns where agent_id = @agent_id and artid = @artid
        insert into dbo.MSsubscription_articlecolumns(agent_id, artid, colid)
        select @agent_id, @artid, colid from sys.fn_replgetcolidfrombitmap(@columns)
        if (@@error != 0)
        begin
            raiserror(21499, 16, 2, @thisspname, 'populate', 'MSsubscription_articlecolumns', @@error)
            return (1)
        end
    end
    -- Do the queue initialization here
    -- this way we can initialize Snapshot/Logbased queued tran from one place
    --
    exec @retcode = sys.sp_MSreset_queue @publisher, @publisher_db, @publication, @artid
    if (@retcode != 0 or @@ERROR != 0)
    begin
        raiserror(21542, 16, 1, @@error, 'sp_MSreset_queue')
        return (1)
    end
    --
    -- all done
    --
    return 0    
END
GO
GRANT EXECUTE ON [sys].[sp_addqueued_artinfo] TO [public] AS [dbo]
GO
