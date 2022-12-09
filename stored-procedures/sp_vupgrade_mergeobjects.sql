SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_vupgrade_mergeobjects]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_vupgrade_mergeobjects] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_vupgrade_mergeobjects]
	@login [sysname],
	@password [sysname],
	@security_mode [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @qual_source_object nvarchar(540),
                @artnick int,
                @objid int,
                @pubid uniqueidentifier,
                @artid uniqueidentifier,
                @retcode int,
                @source_object sysname,
                @source_owner sysname
   
    declare @publication_number smallint
    declare @partition_id_eval_proc sysname
    declare @pubidstr sysname



    -----------------------------------------------------------------
    -- verify input parameters (1,2.3)
    -----------------------------------------------------------------
    -- 1. don't upgrade system databases and distribution databases
     if db_name() in (N'master' COLLATE DATABASE_DEFAULT,
                                N'tempdb' COLLATE DATABASE_DEFAULT,
                                N'msdb'   COLLATE DATABASE_DEFAULT,
                                N'model'   COLLATE DATABASE_DEFAULT)
        or sys.fn_MSrepl_isdistdb (db_name()) = 1
        or databasepropertyex(db_name(), 'Updateability') <> 'READ_WRITE'                                
        return 1

    -- 2. Security Check: require sysadmin
    IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END

    -- 3. Check to ensure a login is provided if security mode is SQL Server authentication.
    select @login = rtrim(ltrim(isnull(@login, '')))
    if @security_mode = 0 and @login = ''
    begin
        -- '@login cannot be null or empty when @security_mode is set to 0 (SQL Server authentication).'
        raiserror(21694, 16, -1, '@login', '@security_mode')
        return 1
    end

    --4. Only upgrade merge databases
    if( object_id('dbo.sysmergearticles') is NULL)
        return 1
                   
    begin tran
    save tran vupgrade_mergeobjects   

    --------------------------------------------------------------------
    -- Loop through each article in the database
    --------------------------------------------------------------------    

    -- regenerate procs that is publication-specific ( not on the article leve)
    declare @pubs table ( pubid uniqueidentifier)  -- a list of publications that has been processed
    declare @snapshot_ready tinyint    
    
    select @artnick = min(nickname) from dbo.sysmergearticles
    while @artnick is not null
    begin
        
        select @objid = NULL
        select @source_object = NULL
        select top 1 @objid = objid, @artid = artid, @pubid = pubid from dbo.sysmergearticles where nickname = @artnick
        select @source_owner = schema_name(schema_id), @source_object = name from sys.objects where object_id = @objid
        if @objid is NULL or @source_object is NULL
            goto error

        -- don't regenerate objects if snapshot has not been run
            select @snapshot_ready = snapshot_ready from dbo.sysmergepublications where pubid = @pubid
            if @snapshot_ready=0
                goto nextarticle        

        -- should we drop trigger before disable triggers?
        exec @retcode = sys.sp_MSdroparticletriggers @source_object, @source_owner
        if @retcode<>0 or @@error<>0
            goto error

        --------------------------------------------------------------------
        -- Step 1: disable DML for all articles in this database  
        --------------------------------------------------------------------            
        exec sys.sp_MScreatedisabledmltrigger @source_object, @source_owner
        if @retcode<>0 or @@error<>0
            goto error

        --------------------------------------------------------------------
        -- Step 2: regenerate triggers and procs
        --------------------------------------------------------------------    

        select @qual_source_object = QUOTENAME(@source_owner) + N'.' + QUOTENAME(@source_object)
        exec sys.sp_MSResetTriggerProcs @qual_source_object, @pubid, 1, 1  --article level reset, regenerate sub procs

        
        -- if this publication has not been processed for regenerating the publication-level objects
        if not exists (select pubid from @pubs where pubid = @pubid)
        begin
            declare @use_partition_groups smallint
            select @use_partition_groups = use_partition_groups from dbo.sysmergepublications where pubid = @pubid
            if (@use_partition_groups > 0) --only do this if we use partition groups
            begin        
	            exec @retcode = sys.sp_MSsetup_publication_for_partition_groups @pubid

	             -- regenerate the partitionid_eval proc, but don't change the table, by setting @upgrade = 1
	            exec @retcode = sys.sp_MSsetup_partition_groups_table @pubid, 1
            end	            

            -- now insert this pubid into the tracking table
            insert into @pubs(pubid) values( @pubid )
        end --if not exists (select pubid from @pubs where pubid = @pubid)

        --------------------------------------------------------------------
        -- Step 3: enable DML for all articles in this database
        --------------------------------------------------------------------

        exec sys.sp_MSdropdisabledmltrigger @source_object, @source_owner
        if @retcode<>0 or @@error<>0
            goto error

nextarticle:
        -- find next article        
        select @artnick = min(nickname) from dbo.sysmergearticles where nickname > @artnick
    end -- end article while
   
    commit tran
            
    return (0)

error: 
    rollback tran vupgrade_mergeobjects
    commit tran
    return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_vupgrade_mergeobjects] TO [public] AS [dbo]
GO
