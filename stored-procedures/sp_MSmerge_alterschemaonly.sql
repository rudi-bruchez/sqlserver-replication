SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_alterschemaonly]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_alterschemaonly] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_alterschemaonly]
	@qual_object_name [nvarchar](512),
	@objid [int],
	@pass_through_scripts [nvarchar](max),
	@objecttype [varchar](32)
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @merge_artid uniqueidentifier 
            ,@pubid uniqueidentifier
            ,@retcode int
            ,@subscription_active int
            ,@include_ddl int

        declare @publisher sysname,
                 @publisher_db sysname,
                     @is_publisher bit,
                     @islightweight bit

    declare @dest_table sysname
            ,@dest_owner sysname             
            ,@qual_dest_object nvarchar(512)

    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    select @include_ddl = 0x1      -- replicate_ddl is turned on by sp_addmergepublication
        ,@subscription_active = 1  -- 1 for active
        ,@retcode = 0

    if is_member('db_owner') <> 1
    begin
        raiserror (21050, 16, -1)
        return (1)
    end

    --alter schema only can be performed only from original publisher of the table.
    --except from merge agent, which propagate ALTER statement to subscribers
    if sessionproperty('replication_agent') <> 1
    begin
            if NOT exists (select * from dbo.sysmergeextendedarticlesview 
                            where objid=@objid and 
                                  pubid in 
                                    (select pubid from dbo.sysmergepublications 
                                        where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and 
                                              publisher_db=db_name()))
            begin
                raiserror(21531, 16, -1)
                return 1
            end
    end

    -- add object owner, object name to pass through script
    
    -- this will always get the pubid of the publisher
    -- if this cmd was executed at the subscriber, error would be thrown by the prev 'IF' condition
    select @pubid =  pubid from dbo.sysmergepublications 
                                where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and 
                                      publisher_db=db_name()
    
     select @dest_table=destination_object, @dest_owner=destination_owner
                                from dbo.sysmergeextendedarticlesview 
                                where pubid=@pubid and objid=@objid
    
    if(@dest_owner is not NULL) and (len(@dest_owner) > 0)
    	select @qual_dest_object = QUOTENAME(@dest_owner) + N'.' 
    else 
    	select @qual_dest_object = N'' 
    
    if(@dest_table is not null) and (len(@dest_table) > 0)
    	select @qual_dest_object = @qual_dest_object + QUOTENAME(@dest_table)
    else 
    	select @qual_dest_object = @qual_object_name                                    
    
    select @pass_through_scripts = N'ALTER ' + @objecttype + N' '
                                + @qual_dest_object + N' '
                                + @pass_through_scripts


    -- real work
    declare @snapshot_ready int, @sync_mode int, @replicate_ddl int

    begin tran
    save tran sp_MSmerge_alterschemaonly

    -- obtain the snapshot/DDL/admin proc applock to avoid having contention with snapshot
    -- Attempt to get the lock with no wait
    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(21386, 16, -1, @qual_object_name)
        goto FAILURE
    end

    select @got_merge_admin_applock = 1

    --loop through relavent publications/articles: note sysmergeschemaarticles exists in both heavy and light weight
    declare #mergepubarticle CURSOR LOCAL FAST_FORWARD for 
        select DISTINCT a.artid, a.pubid, p.publisher, p.publisher_db, p.snapshot_ready, p.sync_mode, p.replicate_ddl
            from sysmergeschemaarticles a 
            join sysmergepublications p on a.pubid = p.pubid 
            join dbo.sysmergesubscriptions s on a.pubid = s.pubid
            where a.objid = @objid 
                    and s.status = @subscription_active 
                    and (p.replicate_ddl & @include_ddl) = @include_ddl

    open #mergepubarticle
    fetch #mergepubarticle into @merge_artid, @pubid, @publisher, @publisher_db, @snapshot_ready, @sync_mode, @replicate_ddl
    while (@@fetch_status <> -1)
    BEGIN
        set @islightweight= null
        select top 1 @islightweight= lightweight from dbo.sysmergearticles where pubid=@pubid

        if 1=@islightweight
        begin
            set @snapshot_ready=0
            set @sync_mode=0
            set @replicate_ddl=0
        end
        
        -- check if this publication is at publisher
        if (
            upper(@publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) 
            and db_name()=@publisher_db
        )
        begin
            set @is_publisher= 1
        end
        else
        begin
            set @is_publisher= 0
        end

        if (1=@is_publisher and 1=@snapshot_ready)
        begin 
            -- translation for SSCE
            if @sync_mode=1 and @replicate_ddl&1<>0
            begin
                set @sync_mode=1
                exec @retcode = sys.sp_MSNonSQLDDLForSchemaDDL @artid = @merge_artid
                                                        , @pubid=@pubid
                                                          ,@ddlcmd = @pass_through_scripts
            end
            -- pass through ddl text for normal db
            if @replicate_ddl&1<>0
            begin
                exec @retcode = sys.sp_MSmerge_passDDLcmd @artid=@merge_artid
                                                        , @pubid=@pubid
                                                          ,@ddlcmd = @pass_through_scripts
            end
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
        end
        fetch #mergepubarticle into @merge_artid, @pubid, @publisher, @publisher_db, @snapshot_ready, @sync_mode, @replicate_ddl
    END
    close #mergepubarticle
    deallocate #mergepubarticle

    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    commit tran
    return 0

DROPTRAN:
    close #mergepubarticle
    deallocate #mergepubarticle

FAILURE:
    IF @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION sp_MSmerge_alterschemaonly
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_alterschemaonly] TO [public] AS [dbo]
GO
