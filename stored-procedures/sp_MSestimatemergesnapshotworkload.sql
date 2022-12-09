SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSestimatemergesnapshotworkload]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSestimatemergesnapshotworkload] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSestimatemergesnapshotworkload]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @taskload                       int
    declare @bigtaskload                    bigint
    declare @table_created                  bit
    declare @retcode                        int

    -- constant
    declare @zerouuid                       uniqueidentifier
    select @zerouuid = convert(uniqueidentifier, N'{00000000-0000-0000-0000-000000000000}')
    -- Publication info
    declare @pubid                          uniqueidentifier
    declare @compress_snapshot              bit
    declare @snapshot_in_defaultfolder      bit
    declare @alt_snapshot_folder            nvarchar(255)
    declare @enabled_for_internet           bit
    declare @ftp_password                   nvarchar(524) 
    declare @ftp_subdirectory               nvarchar(255)
    declare @pre_snapshot_script            nvarchar(255)
    declare @post_snapshot_script           nvarchar(255)    
    declare @dynamic_filters                bit
    declare @allow_subscriber_initiated_snapshot bit

    -- Per publication summary stats
    declare @numarticles                    int
    declare @totalrowcount                  int   
    declare @needsysprescript               bit
    declare @copysnapshot                   bit
    declare @deletefiles                    bit
    declare @scriptproccost                 int
    declare @addcommandstotal               int
    declare @numscripts                     int
    declare @totalbcpcostper100             int
    declare @numprescriptcommands           int 
    declare @numunsyncedarticles            int
    declare @numtablearticles               int
    declare @systablesrowcount              int
    declare @maxint                         int

    select @numarticles = 0
    select @totalrowcount = 0
    select @needsysprescript = 0
    select @copysnapshot = 0
    select @deletefiles = 0
    select @scriptproccost = 0
    select @deletefiles = 0
    select @addcommandstotal = 0
    select @numscripts = 0
    select @totalbcpcostper100 = 0
    select @numprescriptcommands = 0
    select @numunsyncedarticles = 0
    select @numtablearticles = 0
    select @systablesrowcount = 0
    select @maxint = 2147483647

    -- Per article variables
    declare @artid                          uniqueidentifier
    declare @schema_option                  int
    declare @creation_script                nvarchar(255)
    declare @type                           tinyint
    declare @objid                          int
    declare @rowcount                       int
    declare @name                           sysname
    declare @status                         int


    -- Security check
    select @table_created = 0

    select @pubid = null
    select @compress_snapshot = 0
    select @snapshot_in_defaultfolder = 0
    select @alt_snapshot_folder = null
    select @enabled_for_internet = 0
    select @ftp_password = null
    select @ftp_subdirectory = null
    select @pre_snapshot_script = null
    select @post_snapshot_script = null
    -- Validate publication and retrieve publication information 
    select @pubid = pubid, 
           @compress_snapshot = compress_snapshot,
           @snapshot_in_defaultfolder = snapshot_in_defaultfolder,
           @alt_snapshot_folder = alt_snapshot_folder,
           @enabled_for_internet = enabled_for_internet,
           @ftp_password = ftp_password,
           @ftp_subdirectory = ftp_subdirectory,
           @pre_snapshot_script = pre_snapshot_script,
           @post_snapshot_script = post_snapshot_script,
           @dynamic_filters = dynamic_filters,
           @allow_subscriber_initiated_snapshot = allow_subscriber_initiated_snapshot
           from dbo.sysmergepublications
     where name = @publication
       and upper(publishingservername()) = upper(publisher)
       and publisher_db = db_name()
    if @pubid = null
    begin   
        raiserror(21423, 11, -1, @publication)
        return (1)
    end

   -- security check. Enforce replcheck publish incase this
   -- is not a dynamically filtered publication
   if @dynamic_filters = 0 or @allow_subscriber_initiated_snapshot = 0
   begin
        if (is_member('db_owner') <> 1)
        begin
            RAISERROR (21423, 11, -1, @publication)
            return (1)
        end
   end
   else
   begin
        if ({ fn ISPALUSER(@pubid) } <> 1)
        begin    
            RAISERROR (21423, 11, -1, @publication)
            return (1)
        end
   end

    -- An artid of -1 means the task is a per publication
    -- task

    -- Task id mapping - This is the list of task whose completion can be 
    -- reported by the snapshot agent
    -- 0 - Total workload (not really a task)
    -- 1 - Schema script generation
    -- 2 - Trigger script generation 
    -- 3 - XProp script generation
    -- 4 - Bcp file generation
    -- 5 - Activating subscription (estimate number of subscriptions?)
    -- 6 - Adding snapshot commands
    -- 7 - System pre-script generation
    -- 8 - Flushing folder for scripts
    -- 9 - Constraint script generation
    -- 10 - Copying pre-script
    -- 11 - Copying post-script
    -- 12 - Copying custom schema creation script
    -- 13 - Index script generation
    -- 14 - Flushing the cabinet
    -- 15 - Adding rowguid column
    -- 16 - Setting article procs
    -- 17 - Adding merge triggers
    -- 18 - Generating system table scripts
    -- 19 - Generating system table bcp files
    -- 20 - Making publication generation
    -- 21 - Generating and setting conflict script
    -- 22 - Generating publication views
    
    -- Weights and overheads
    -- DMO Script generation - 7/script
    -- BCP 5 overhead + 5/100 rows
    -- Flush folder for bcp 2/100 rows
    -- Delete file 2
    -- System pre-snapshot script 1 overhead + 0.5/pre-creation command
    -- Copying user file 2
    -- Adding file to cabinet 1 for scripts and 1/100 rows in bcp file
    -- Loading article info 3
    -- Delete bcp file 2/100rows 
    -- Copy bcp file  2/100rows  
    -- Flush scripts folder 1/2 scripts
    -- Flushing cabinet per 5 scripts 1
    -- Flushing cabinet per 500 rows 1
    -- Script execution 3
    -- Adding rowguid columns 20/100 rows
    -- Adding merge triggers 7
    -- Setting article procs 5

    -- Here is the list of cost factors 
    declare @addcommandcost     int
    declare @dmoscriptcost      int
    declare @bcpoverhead        int
    declare @bcpcostper100      int
    declare @flushper100        int
    declare @flushperscript     int
    declare @delfilecost        int
    declare @syspreoverhead     int
    declare @syspreper2commands int
    declare @addbcptocabper100  int
    declare @addscripttocab     int
    declare @copyfilecost       int
    declare @loadartinfo        int    
    declare @deletebcpper100    int
    declare @copybcpper100      int
    declare @flushper2scripts   int
    declare @flushcabper5scripts int
    declare @flushcabper500bcprows int
    declare @scriptexeccost int
    declare @rowguidper100 int
    declare @addmergetriggers int
    declare @setartprocs int
    declare @pubviewperarticle int
    declare @genperarticle int

    select @addcommandcost = 2
    select @dmoscriptcost = 7
    select @bcpcostper100 = 20
    select @bcpoverhead = 2
    select @flushper100 = 2
    select @flushperscript = 3
    select @delfilecost = 2
    select @syspreoverhead = 1
    select @syspreper2commands = 1
    select @addbcptocabper100 = 1
    select @addscripttocab = 1
    select @copyfilecost = 2
    select @loadartinfo = 3    
    select @deletebcpper100 = 1
    select @copybcpper100 = 2
    select @flushper2scripts = 1
    select @flushcabper5scripts = 1
    select @flushcabper500bcprows = 1
    select @scriptexeccost = 3
    select @rowguidper100 = 20
    select @addmergetriggers = 3
    select @pubviewperarticle = 2
    select @genperarticle = 2
    select @setartprocs = 5

    create table #workload_breakdown
    (
        name        sysname collate database_default,
        artid       uniqueidentifier,
        taskid      int,
        taskload    int
    )
    if @@error <> 0
        goto Failure

    select @table_created = 1

    -- Per publication work load estimate that can be done using publication
    -- properties alone
    
    -- Adding snapshot header commands
    
    -- Snapshot header begins + Snapshot header ends +
    -- directory command + Snapshot trailer command = 3 * @addcommandcost
    select @addcommandstotal = 4
    
    -- Alternate snapshot folder = 1 * @addcommandcost
    if @alt_snapshot_folder is not null and
       @alt_snapshot_folder <> N'' and
       @snapshot_in_defaultfolder = 1
    begin
        select @addcommandstotal = @addcommandstotal + @addcommandcost
    end

    -- Ftp commands
    if @enabled_for_internet = 1
    begin
        -- ftp_address and ftp_port must be there +=2 * @addcommandcost
        select @addcommandstotal = @addcommandstotal + 2 * @addcommandcost

        -- ftp_password += 1 * @addcommandcost
        if @ftp_password is not null and
           @ftp_password <> N''
        begin
            select @addcommandstotal = @addcommandstotal + @addcommandcost
        end
        
        -- ftp_subdirectory += 1 * @addcommandcost
        if @ftp_subdirectory is not null and
           @ftp_subdirectory <> N''
        begin
            select @addcommandstotal = @addcommandstotal + 1 * @addcommandcost
        end
    end

    -- Compressed archive path
    if @compress_snapshot = 1
    begin
        select @addcommandstotal = @addcommandstotal + 1 * @addcommandcost
    end    

    -- Snapshot trailer command
    select @addcommandstotal = @addcommandstotal +  @addcommandcost

    -- Need to copy files?
    if @alt_snapshot_folder is not null and @alt_snapshot_folder <> N''
       and @snapshot_in_defaultfolder = 1 and @compress_snapshot = 0
    begin
        select @copysnapshot = 1
    end

    -- Compute per-script file post processing cost and bcp cost per 100 rows
    -- Need to delete files?
    if (@alt_snapshot_folder is null or @alt_snapshot_folder <> N''
       or @snapshot_in_defaultfolder = 0) and @compress_snapshot = 1
    begin
        select @deletefiles = 1
    end

    select @totalbcpcostper100 = @bcpcostper100
    -- Copy file?
    if @copysnapshot = 1
    begin
        select @scriptproccost = @scriptproccost + @copyfilecost
        select @totalbcpcostper100 = @totalbcpcostper100 + @copybcpper100
    end

    -- Add file to cabinet?
    if @compress_snapshot = 1
    begin
        select @scriptproccost = @scriptproccost + @addscripttocab 
        select @totalbcpcostper100 = @totalbcpcostper100 + @addbcptocabper100
    end

    -- Delete file?
    if @deletefiles = 1
    begin 
        select @scriptproccost = @scriptproccost + @delfilecost
        select @totalbcpcostper100 = @totalbcpcostper100 + @deletebcpper100
    end

    -- Pre/Post-snapshot scripts, has to be computed after the 
    -- the per-script post-processing cost is calculated 
    if @pre_snapshot_script is not null and
       @pre_snapshot_script <> N''
    begin
        -- Cost of copying the script file
        select @taskload = @copyfilecost + @scriptproccost
        insert #workload_breakdown values (N'', @zerouuid, 10, @taskload)
        -- Cost of adding the pre-snapshot command
        select @addcommandstotal = @addcommandstotal + @addcommandcost
        -- Increment scripts counter
        select @numscripts = @numscripts + 1
    end

    if @post_snapshot_script is not null and
       @post_snapshot_script <> N''
    begin
        -- Cost of copying the script file
        select @taskload = @copyfilecost + @scriptproccost
        insert #workload_breakdown values (N'', @zerouuid, 11, @taskload)
        -- Cost of adding the post-snapshot command
        select @addcommandstotal = @addcommandstotal + @addcommandcost
        -- Increment scripts counter
        select @numscripts = @numscripts + 1
    end
           
    -- Estimate the break down of per article tasks 
    declare hCarticles cursor local fast_forward
    for select artid, creation_script, objid, convert(int, schema_option), type, name,
               status  
          from dbo.sysmergeextendedarticlesview where pubid = @pubid 

    open hCarticles
   
    fetch hCarticles into @artid, @creation_script, @objid, @schema_option, @type, @name,
        @status
    while (@@fetch_status <> -1)
    begin
        if @type = 0x40 -- Schema view articles, may require index scripting
        begin
            select @taskload = 0
            -- See if a custom creation script will be used 
            if @schema_option = 0 and @creation_script is not null and
               @creation_script <> N''
            begin
                -- Script generation
                select @taskload = @copyfilecost + @scriptproccost
                insert #workload_breakdown values (@name, @artid, 12, @taskload)
                -- Cost of adding commands for the custom script
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1
                -- No need to worry about index script
            end
            else
            begin
                -- Script generation 
                select @taskload = @dmoscriptcost + @scriptproccost
                -- Must script out schema script
                insert #workload_breakdown values (@name, @artid, 1, @taskload)
                -- Cost of adding the command
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1

                -- DRI script containing the view's indexes?
                if (@schema_option & 0x50) <> 0x0
                begin
                    -- Cost of script generation
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 9, @taskload)
                    -- Cost of adding command for the script
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                    -- Increment scripts counter
                    select @numscripts = @numscripts + 1
                end

                -- Trigger script?
                if (@schema_option & 0x100) <> 0x0
                begin
                    -- Cost of script generation
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 2, @taskload)
                    -- Cost of adding command for the script
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                    -- Increment scripts counter
                    select @numscripts = @numscripts + 1
                end 

                -- XProp script?
                if (@schema_option & 0x2000) <> 0x0
                begin
                    -- Cost of script generation 
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 3, @taskload)
                    -- Cost of adding command
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                    -- Increment scripts counter
                    select @numscripts = @numscripts + 1
                end
            end        
        end
        else if @type in (0x08, 0x18, 0x20, 0x80, 0xA0) -- Regular schema articles 
        begin
            select @taskload = 0
            -- See if a custom creation script will be used 
            if @schema_option = 0 and @creation_script is not null and
               @creation_script <> N''
            begin
                -- Script generation
                select @taskload = @copyfilecost + @scriptproccost
                insert #workload_breakdown values (@name, @artid, 12, @taskload)
                -- Cost of adding commands for the custom script
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1
            end
            else 
            begin
                -- Script generation 
                select @taskload = @dmoscriptcost + @scriptproccost
                -- Must script out schema script
                insert #workload_breakdown values (@name, @artid, 1, @taskload)
                -- Cost of adding the command
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1

                -- XProp script?
                if (@schema_option & 0x2000) <> 0x0
                begin
                    -- Cost of script generation 
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 3, @taskload)
                    -- Cost of adding command
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1
                end
            end
        end
        else -- Merge table articles, requires bcp
        begin
           select @taskload = 0
           -- See if a custom creation script will be used 
            if @schema_option = 0 and @creation_script is not null and
               @creation_script <> N''
            begin
                -- Script generation
                select @taskload = @copyfilecost + @scriptproccost
                insert #workload_breakdown values (@name, @artid, 12, @taskload)
                -- Cost of adding commands for the custom script
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1
                -- No need to worry about index script
            end
            else
            begin
                -- Script generation 
                select @taskload = @dmoscriptcost + @scriptproccost
                -- Must script out schema script
                insert #workload_breakdown values (@name, @artid, 1, @taskload)
                -- Cost of adding the command
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1

                -- Constraint script is not optional for merge table article
                -- Cost of script generation
                select @taskload = @dmoscriptcost + @scriptproccost
                insert #workload_breakdown values (@name, @artid, 9, @taskload)
                -- Cost of adding command for the script
                select @addcommandstotal = @addcommandstotal + @addcommandcost
                -- Increment scripts counter
                select @numscripts = @numscripts + 1
    
                -- Trigger script?
                if (@schema_option & 0x100) <> 0x0
                begin
                    -- Cost of script generation
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 2, @taskload)
                    -- Cost of adding command for the script
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                    -- Increment scripts counter
                    select @numscripts = @numscripts + 1
                end 
        
                -- XProp script?
                if (@schema_option & 0x2000) <> 0x0
                begin
                    -- Cost of script generation 
                    select @taskload = @dmoscriptcost + @scriptproccost
                    insert #workload_breakdown values (@name, @artid, 3, @taskload)
                    -- Cost of adding command
                    select @addcommandstotal = @addcommandstotal + @addcommandcost
                    -- Increment scripts counter
                    select @numscripts = @numscripts + 1
                end
            end        

            -- Conflict script generation and setting
            -- Cost of script generation and execution 
            select @taskload = @dmoscriptcost + @scriptexeccost + @scriptproccost
            insert #workload_breakdown values (@name, @artid, 21, @taskload)

            -- Get fast row count from sysindexes for bcp op estimation
            select @rowcount = 
                    case when isnull(rowcnt,0) > @maxint then @maxint / 10000
                         when isnull(rowcnt,0) > @maxint / 10000 then rowcnt / 10000
                         else isnull(rowcnt,0)
                    end
              from sysindexes 
             where id = @objid and indid in (0,1)

            -- For unsynced articles, we need to 
            -- 1) Add rowguid column 
            -- 2) Set article procs
            -- 3) Add merge triggers
            if @status = 1
            begin
                -- Add rowguid column - use article row count to estimate the cost
                select @taskload = (@rowcount * @rowguidper100) / 100
                insert #workload_breakdown values (@name, @artid, 15, @taskload) 
      
                -- Set article procs
                select @taskload = @setartprocs
                insert #workload_breakdown values (@name, @artid, 16, @taskload)

                -- Add merge triggers    
                select @taskload = @addmergetriggers 
                insert #workload_breakdown values (@name, @artid, 17, @taskload)

                -- Increment the number of unsynced articles
                select @numunsyncedarticles = @numunsyncedarticles + 1
            end

            -- Increment the total row count
            select @totalrowcount = @totalrowcount + @rowcount        

            -- BCP computation            
            -- Bcp file generation
            select @taskload = @bcpoverhead + (@rowcount * @totalbcpcostper100) / 100 
            insert #workload_breakdown values (@name, @artid, 4, @taskload)

            -- Increment the table articles counter
            select @numtablearticles = @numtablearticles + 1

        end    

        -- System pre-snapshot script required?
        if @type in (0x40, 0x80)
        begin
            select @needsysprescript = 1
            -- Incrememt the number of pre-script command counter
            select @numprescriptcommands = @numprescriptcommands + 1
        end

        -- Increment the article count
        select @numarticles = @numarticles + 1

        fetch hCarticles into @artid, @creation_script, @objid, @schema_option, @type, @name,
            @status
    end
        
    -- The cost of making publication views depends upon the 
    -- number of unsynced articles
    if @numunsyncedarticles <> 0
    begin
        select @taskload = @numunsyncedarticles * @pubviewperarticle 
        insert #workload_breakdown values (N'', @zerouuid, 22, @taskload) 
    end

    -- Make publication generation - roughly proportional to the number of table
    -- articles we have
    select @taskload = @numtablearticles * @genperarticle
    insert #workload_breakdown values (N'', @zerouuid, 20, @taskload)

    -- Merge system tables processing 
    -- Script files
    select @taskload = 4 * (@dmoscriptcost + @scriptproccost)
    insert #workload_breakdown values (N'', @zerouuid, 18, @taskload)

    -- Cost of adding the commands
    select @addcommandcost = @addcommandcost + 4

    -- Bcp files - Generated only when the publication is not enabled for
    -- dynamic filters
    if @dynamic_filters = 0
    begin
        if object_id(N'MSmerge_contents') is not NULL
        begin
            select @rowcount =
                    case when isnull(rowcnt,0) > @maxint then @maxint / 10000
                         when isnull(rowcnt,0) > @maxint / 10000 then rowcnt / 10000
                         else isnull(rowcnt,0)
                    end
              from sysindexes where id = object_id('MSmerge_contents') 
               and indid in (0,1)
            select @systablesrowcount = @systablesrowcount + @rowcount
        end
        if exists (select * from sys.objects where name = N'MSmerge_tombstones')
        begin
            select @rowcount =
                    case when isnull(rowcnt,0) > @maxint then @maxint / 10000
                         when isnull(rowcnt,0) > @maxint / 10000 then rowcnt / 10000
                         else isnull(rowcnt,0)
                    end
              from sysindexes 
             where id = object_id('MSmerge_tombstones') 
               and indid in (0,1)
            select @systablesrowcount = @systablesrowcount + @rowcount
        end
        if object_id(N'MSmerge_genhistory') is not NULL
        begin
            select @rowcount = 
                    case when isnull(rowcnt,0) > @maxint then @maxint / 10000
                         when isnull(rowcnt,0) > @maxint / 10000 then rowcnt / 10000
                         else isnull(rowcnt,0)
                    end
              from sysindexes 
             where id = object_id('MSmerge_genhistory') 
               and indid in (0,1)
            select @systablesrowcount = @systablesrowcount + @rowcount
        end
    end
    if object_id(N'sysmergesubsetfilters') is not NULL
    begin
        select @rowcount = count(*) from dbo.sysmergesubsetfilters
        select @systablesrowcount = @systablesrowcount + @rowcount 
    end

    select @taskload = (4 * @bcpoverhead) + (@systablesrowcount * @totalbcpcostper100) / 100 
    insert #workload_breakdown values (N'', @zerouuid, 19, @taskload)
    select @totalrowcount = @totalrowcount + @systablesrowcount

    -- System pre-snapshot script processing cost 
    if @needsysprescript = 1
    begin
        select @taskload = @syspreoverhead + 
                (@numprescriptcommands * @syspreper2commands) / 2 +
               @scriptproccost
        insert #workload_breakdown values (N'', @zerouuid, 7, @taskload)         
        select @numscripts = @numscripts + 1
    end

    -- Cost of flushing folder for the scripts 
    if @compress_snapshot = 1
    begin
        select @taskload = (@numscripts * @flushper2scripts) / 2
        insert #workload_breakdown values (N'', @zerouuid, 8, @taskload) 
    end

    -- Cost for flushing the cabinet
    if @compress_snapshot = 1
    begin
        select @taskload = (@numscripts * @flushcabper5scripts / 5) +
                           (@totalrowcount * @flushcabper500bcprows / 500)
        insert #workload_breakdown values (N'', @zerouuid, 14, @taskload)
    end

    -- Add the total add commands cost
    insert #workload_breakdown values (N'', @zerouuid, 6, @addcommandstotal)

    -- Compute the total workload and put that in the 
    -- workload break down
    select @bigtaskload = sum(convert(bigint,taskload)) from #workload_breakdown
    select @taskload =
            case when @bigtaskload > @maxint then @maxint
            else @bigtaskload
            end
    insert #workload_breakdown values (N'', @zerouuid, 0, @taskload) 

    select name, taskid, taskload from #workload_breakdown order by artid, taskid asc
    drop table #workload_breakdown
    return 0

Failure:
    if @table_created = 1
       drop table #workload_breakdown
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSestimatemergesnapshotworkload] TO [public] AS [dbo]
GO
