SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_altertrigger]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_altertrigger] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_altertrigger]
	@qual_object_name [nvarchar](512),
	@objid [int],
	@pass_through_scripts [nvarchar](max),
	@target_object_name [nvarchar](512)
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @merge_artid uniqueidentifier 
            ,@pubid uniqueidentifier
            ,@retcode int
            ,@subscription_active int
            ,@include_ddl int
            ,@replicate_trigger int
            ,@dest_table sysname
            ,@dest_owner sysname
            ,@qual_dest_object nvarchar(512)
            ,@temp_ddlcmds nvarchar(max)

    select @include_ddl = 0x1         -- replicate_ddl is turned on by sp_addmergepublication
        ,@subscription_active = 1  -- 1 for active
        ,@retcode = 0
        ,@replicate_trigger = 0x100

        declare @publisher sysname,
                     @publisher_db sysname,
                     @is_publisher bit,
                     @islightweight bit,
                     @qual_dest_object2 nvarchar(512)

    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    if is_member('db_owner') <> 1
    begin
        raiserror (21050, 16, -1)
        return (1)
    end

    -- Check if hws or lws, return if not heavyweight.    
    select top 1 @islightweight= lightweight
        from dbo.sysmergearticles where object_name(objid)=@target_object_name

    if @islightweight is null
    begin
        return 0
    end

    --alter trigger only can be performed only from original publisher of the table.
    --except from merge agent, which propagate ALTER statement to subscribers
    if sessionproperty('replication_agent') <> 1
    begin
        if 0=@islightweight
        begin
            if NOT exists (select * from dbo.sysmergearticles a join sys.objects o 
                            on 
                                a.objid = o.parent_object_id 
                            where
                                  o.object_id = @objid and 
                                  a.pubid in 
                                    (select pubid from dbo.sysmergepublications 
                                        where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and 
                                              publisher_db=db_name()))
            begin
                raiserror(21531, 16, -1)
                return 1
            end
        end
        else
        begin
            raiserror(21531, 16, -1)
            return 1
         end
    end

    -- real work
    declare @snapshot_ready int, @sync_mode int, @replicate_ddl int

    begin tran
    save tran sp_MSmerge_altertrigger

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

    --loop through relavent publications/articles: we must be in heavy weight as we will use sysmergearticles
    declare #mergepubarticle CURSOR LOCAL FAST_FORWARD for 
        select DISTINCT a.artid, a.pubid, p.publisher, p.publisher_db, p.snapshot_ready, p.sync_mode, p.replicate_ddl
                ,a.destination_object, a.destination_owner
            from sysmergearticles a 
            join sys.objects o on a.objid = o.parent_object_id
            join sysmergepublications p on a.pubid = p.pubid 
            join dbo.sysmergesubscriptions s on a.pubid = s.pubid
            where o.object_id = @objid 
                    and s.status = @subscription_active 
                    and (p.replicate_ddl & @include_ddl) = @include_ddl
                    and (a.schema_option & @replicate_trigger) = @replicate_trigger

    open #mergepubarticle
    fetch #mergepubarticle into @merge_artid, @pubid, @publisher, @publisher_db, @snapshot_ready, @sync_mode, @replicate_ddl
            ,@dest_table, @dest_owner
    while (@@fetch_status <> -1)
    BEGIN
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
                -- use 2 part naming
                if(@dest_owner is not NULL) and (len(@dest_owner) > 0)
                    select @qual_dest_object2 = QUOTENAME(@dest_owner) + N'.' 
                else 
                    select @qual_dest_object2 = N'' 
                if(@dest_table is not null) and (len(@dest_table) > 0)
                    select @qual_dest_object2 = @qual_dest_object2 + QUOTENAME(@dest_table)
                else 
                    select @qual_dest_object2 = @target_object_name
                -- prepare ddl cmd
                -- select @temp_ddlcmds = N'ALTER TRIGGER ' 
                --                                + @qual_object_name + N' on ' 
                --                                + @qual_dest_object2 + N' '
                --                                + @pass_through_scripts

                
                select @temp_ddlcmds = N'if object_id(N''' + sys.fn_replreplacesinglequote(@qual_object_name) + N''') is not null exec(''' 				
                                                + sys.fn_replreplacesinglequote('ALTER TRIGGER '
                                                + @qual_object_name + N' on '
                                                + @qual_dest_object2 + N' '
                                                + @pass_through_scripts )+ N''')'
                
                -- save it
                exec @retcode = sys.sp_MSmerge_passDDLcmd @artid=@merge_artid
                                                        , @pubid=@pubid
                                                          ,@ddlcmd = @temp_ddlcmds
            end
            if @retcode <>0 or @@ERROR<>0
                goto DROPTRAN
        end
        fetch #mergepubarticle into @merge_artid, @pubid, @publisher, @publisher_db, @snapshot_ready, @sync_mode, @replicate_ddl
                    ,@dest_table, @dest_owner

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
        rollback tran sp_MSmerge_altertrigger
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_altertrigger] TO [public] AS [dbo]
GO
