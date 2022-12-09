SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_vupgrade_replication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_vupgrade_replication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_vupgrade_replication]
	@login [sysname],
	@password [sysname],
	@ver_old [int],
	@force_remove [tinyint],
	@security_mode [bit]
WITH EXECUTE AS CALLER
AS
begin

    -- TEST: This line was added to test proc updates on the patching improvement

    set nocount on 

    declare @dbname sysname
    declare @has_dbaccess bit
    declare @retcode int
    declare @cmd nvarchar(4000)

    -- db bits
    declare @db_distbit int
    select @db_distbit = 16

    -- version check
    declare @ver_min            int
    declare @ver_retention        int

    select @ver_retention = 576 --build # on 9/17

    -- raiserror('sp_vupgrade_replication', 0,1) with nowait
    /*
    ** Security Check: require sysadmin
    */
    IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END

    -- Check to ensure a login is provided if security mode is SQL Server authentication.
    select @login = rtrim(ltrim(isnull(@login, '')))
    if @security_mode = 0 and @login = ''
    begin
        -- '@login cannot be null or empty when @security_mode is set to 0 (SQL Server authentication).'
        raiserror(21694, 16, -1, '@login', '@security_mode')
        return 1
    end

    /*
    ** Mark master.dbo.MSreplication_options as system object so it can be freely
    ** accessible by resource database objects
    */
    if object_id('master.dbo.MSreplication_options', 'U') is not null
    begin
        exec master.dbo.sp_MS_marksystemobject 'dbo.MSreplication_options'
    end

    /*
     * obsolete check; ver check was to prevent repl upgrade from
     * versions prior to SQL7.0 Beta 3; check is removed by setting @ver_min = -1
    */
    select @ver_min= -1 -- change if later wish to support a minimum upgrade version
    if ( @ver_old < @ver_min ) or ( @force_remove = 1 )
        exec sys.sp_removesrvreplication
    else
    begin
        /* 
         * always need to run instdist.sql to update distribution databases on a distributor
         * setup must restart in non-single user mode so we can shell out to run instdist.sql scripts
        */
        if exists( select * from master.dbo.sysdatabases where category & @db_distbit = @db_distbit )
        begin
            /*
             * Upgrade replication schema and metadata in msdb database -- ONLY FOR DISTRIBUTORS
            */
            exec @retcode = sys.sp_vupgrade_replmsdb
            if @retcode <> 0 or @@error <> 0
                    return (1)
            --
            -- Enumerate distribution databases
            --
            declare #cur_distdb CURSOR LOCAL FAST_FORWARD for 
                select name, has_dbaccess(name) from master.dbo.sysdatabases 
                    where category & @db_distbit = @db_distbit
                    		and databasepropertyex(name, 'Updateability') = 'READ_WRITE'
                for read only

            open #cur_distdb
            fetch #cur_distdb into @dbname, @has_dbaccess
            while ( @@fetch_status <> -1 )
            begin
              -- Verify that this SKU is allowed to be a distributor, otherwise unmark the dist bit but leave the db as is
				exec @retcode = sys.sp_MSsku_allows_replication
				if @@error <> 0 or @retcode <> 0
				begin
					EXEC %%DatabaseEx(Name = @dbname).SetDistributor(Value = 0)					
				end
              -- if distribution database is available upgrade it; if offline error out
				else if ( @has_dbaccess = 1 )
                begin
                    raiserror( 21374, 0, 1, @dbname) with nowait
                    --We dont want to hardcode the compatibility level to 90. Done as part of VSTS 1232210 (Setting compatibility level of Distribution DB to match server level)
                    declare @cmptlevelmaster tinyint,@cmptlevel tinyint
                    select @cmptlevelmaster = cmptlevel from master.dbo.sysdatabases where name = 'master'
                    select @cmptlevel = cmptlevel from master.dbo.sysdatabases where name = @dbname
                    if (@cmptlevel != @cmptlevelmaster)
                    begin
                    raiserror(21762,10, 1, @dbname, @cmptlevel, @cmptlevelmaster)    
                    EXEC %%DatabaseEx(Name = @dbname).SetCompatibility(Level =@cmptlevelmaster)
                    end

                    select @cmd = quotename(@dbname) + N'.sys.sp_instdist'
                    exec @cmd
                    if @@error <> 0
                        return(1)
                    if serverproperty('EngineEdition') = 8 begin -- Defect 11550616: execute it outside of sp_instdist in CL only, to workaround known problem
                        select @cmd = quotename(@dbname) + N'.dbo.sp_MS_marksystemobject'
                        exec @retcode = @cmd N'dbo.sp_MSset_syncstate'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSadd_repl_commands27'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSadd_replcmds'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSremove_published_jobs'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSsubscription_cleanup'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSdelete_publisherdb_trans'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSmaximum_cleanup_seqno'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSdistribution_delete'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSdistribution_cleanup'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MShistory_cleanup'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSget_repl_version'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.MSdistribution_status'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSlog_agent_cancel'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.sp_MSdelete_dodelete'
                        if @retcode <> 0 or @@error <> 0 return(1)
                        exec @retcode = @cmd N'dbo.fn_MSmask_agent_type'
                        if @retcode <> 0 or @@error <> 0 return(1)
                    end

                    /*
                     * Process schema and metadata changes for each distribution database
                    */

                    select @cmd = quotename(@dbname) + N'.sys.sp_vupgrade_distdb'
                    exec @cmd
                    if @@error <> 0
                        return(1)
                end
                else
                begin
                    -- all distribution databases must be upgraded before continuing
                    raiserror( 21378, 16, 1, @dbname) with nowait
                end
                
                fetch next from #cur_distdb into @dbname, @has_dbaccess
            end -- end while fetch for distdb processing
            close #cur_distdb
            deallocate #cur_distdb
        end -- process distributors

        -- vupgrade_publisher runs at 
       exec @retcode = sys.sp_vupgrade_publisher 
               @ver_old = @ver_old, 
               @ver_retention = @ver_retention
        if @retcode<>0 or @@error<>0
            return (1)
    
        -- Update subscription database schema
        exec @retcode = sys.sp_vupgrade_subscription_databases
        if @retcode <> 0 or @@error <> 0
            return (1)

        exec sys.sp_vupgrade_registry
        if @retcode <> 0 or @@error <> 0
            return (1)
            
        if (sys.fn_MSrepl_editionid() in (22, 40))-- Express or Web
        begin
            exec @retcode = sys.sp_vupgrade_express_edition
            if @retcode <> 0 or @@error <> 0
                return 1
        end
    end

    --
    -- Upgrade metadata for defined Oracle publishers
    -- Ignore all errors for now because we do not want replication
    -- upgrade to fail even if Oracle publishing upgrade has some problems.
    begin try
        exec @retcode = sys.sp_vupgrade_heterogeneous_publishers
    end try
    begin catch
        select @retcode = 0
    end catch
    
    -- Upgrade metadata for CDC enabled databases.
    -- Note: sp_cdc_vupgrade_databases catches all raised errors,
    -- and outputs informational messages only. We should not fail
    -- here, even if upgrade fails for one or more CDC enabled databases.
    exec sys.sp_cdc_vupgrade_databases
    
	-- Upgrade SQL Agent job or metadata for distributor
    exec sys.sp_vupgrade_distributor
        if @retcode <> 0 or @@error <> 0
            return (1)
    --
    -- all done
    --
    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_vupgrade_replication] TO [public] AS [dbo]
GO
