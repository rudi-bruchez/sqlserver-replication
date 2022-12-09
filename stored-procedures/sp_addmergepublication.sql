SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergepublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergepublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergepublication]
	@publication [sysname],
	@description [nvarchar](255),
	@retention [int],
	@sync_mode [nvarchar](10),
	@allow_push [nvarchar](5),
	@allow_pull [nvarchar](5),
	@allow_anonymous [nvarchar](5),
	@enabled_for_internet [nvarchar](5),
	@centralized_conflicts [nvarchar](5),
	@dynamic_filters [nvarchar](5),
	@snapshot_in_defaultfolder [nvarchar](5),
	@alt_snapshot_folder [nvarchar](255),
	@pre_snapshot_script [nvarchar](255),
	@post_snapshot_script [nvarchar](255),
	@compress_snapshot [nvarchar](5),
	@ftp_address [sysname],
	@ftp_port [int],
	@ftp_subdirectory [nvarchar](255),
	@ftp_login [sysname],
	@ftp_password [sysname],
	@conflict_retention [int],
	@keep_partition_changes [nvarchar](5),
	@allow_subscription_copy [nvarchar](5),
	@allow_synctoalternate [nvarchar](5),
	@validate_subscriber_info [nvarchar](500),
	@add_to_active_directory [nvarchar](5),
	@max_concurrent_merge [int],
	@max_concurrent_dynamic_snapshots [int],
	@use_partition_groups [nvarchar](5),
	@publication_compatibility_level [nvarchar](6),
	@replicate_ddl [int],
	@allow_subscriber_initiated_snapshot [nvarchar](5),
	@allow_web_synchronization [nvarchar](5),
	@web_synchronization_url [nvarchar](500),
	@allow_partition_realignment [nvarchar](5),
	@retention_period_unit [nvarchar](10),
	@generation_leveling_threshold [int],
	@automatic_reinitialization_policy [bit],
	@conflict_logging [nvarchar](15)
WITH EXECUTE AS CALLER
AS
set nocount on

    /*
    ** Declarations.
    */
    
    declare @retcode                    int            /* return code value for procedure execution */
    declare @push                        tinyint        /* subscription type is push */
    declare @statid                        tinyint        /* status id based on @status */
    declare @sync_modeid                tinyint        /* sync mode id based on @sync_mode */
    declare @global                        tinyint        /* subscriber type of loop-back subscription */
    declare @db_name                    sysname        /* database name */
    declare @replnick                    binary(6)    /* replica nickname */
    declare @tranpublish_bit            smallint    /* online publish bit (flag) in sysdatabases */
    declare @mergepublish_bit            smallint    /* merge publish bit (flag) in sysdatabases */
    declare @found                        int            /* flag indicating if publication is found */
    declare @pubid                        uniqueidentifier    /* Publication identifier */
    declare @allow_push_id                bit
    declare @allow_pull_id                bit
    declare @allow_anonymous_id            bit
    declare @dynamic_filters_id            bit            
    declare @allow_subscription_copy_id bit            
    declare @allow_synctoalternate_id    bit            
    declare @allow_web_synchronization_id    bit            
    declare @enabled_for_internet_id    bit
    declare @conflogging                int
    declare @priority                    real        
    declare @automatic                    tinyint        
    declare @false                        bit
    declare @true                        bit
    declare @distributor                sysname
    declare @distproc                    nvarchar(300)
    declare @distribdb                    sysname
    declare @distpubid                    int
    declare @full                        int
    declare @snapshot_in_defaultfolder_bit        bit
    declare @compress_snapshot_bit        bit
    declare @keep_before_values_int        int
    declare @enc_ftp_password            nvarchar(524)
    declare @ad_guidname                sysname
    declare @schemaversion                int 
    declare @schemaguid                    uniqueidentifier
    declare @schematype                    int
    declare @schematext                    nvarchar(2000)
    declare @artid                        uniqueidentifier
    declare @distservername                sysname
    declare @use_partition_groups_id    smallint
    declare @allow_subscriber_initiated_snapshot_id bit
    declare @allow_partition_realignment_id         bit
    declare @REPOLEVersion_70RTM        int
    declare @REPOLEVersion_70SP1        int
    declare @REPOLEVersion_70SP2        int
    declare @REPOLEVersion_80RTM        int
    declare @REPOLEVersion_90            int
    declare @REPOLEVersion_100            int    
    declare @REPOLEVersion_70RTM_string        nvarchar(5)
    declare @REPOLEVersion_70SP1_string        nvarchar(5)
    declare @REPOLEVersion_70SP2_string        nvarchar(5)
    declare @REPOLEVersion_70SP3_string        nvarchar(5)
    declare @REPOLEVersion_70SP4_string        nvarchar(5)
    declare @REPOLEVersion_80RTM_string        nvarchar(5)
    declare @REPOLEVersion_80SP1_string        nvarchar(5)
    declare @REPOLEVersion_80SP2_string        nvarchar(5)
    declare @REPOLEVersion_80SP3_string        nvarchar(5)
    declare @REPOLEVersion_90RTM_string        nvarchar(5)
    declare @REPOLEVersion_100RTM_string        nvarchar(6)    
    declare @pubcompat_level_id int
    declare @retention_period_unit_id        tinyint
    declare @working_directory      nvarchar(255)
    			,@publishingservername sysname
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

        
    if (sys.fn_MSrepl_editionid() in (22, 40)) -- SQL Express or SQL_Web
    begin
        raiserror(21106, 16, -1) --This edition of SQL Server does not support publications. 
        return (1)
    end

    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    select @mergepublish_bit    = 4 
    select @tranpublish_bit        = 1
    select @priority            = 100.0
    select @automatic            = 1        /* Const: synchronization type 'automatic' */
    select @true                = 1
    select @false                = 0
    select @full                = 0        /* Const: publication type 'full' */

    set @REPOLEVersion_70RTM= 10
    set @REPOLEVersion_70SP1= 20
    set @REPOLEVersion_70SP2= 30
    set @REPOLEVersion_80RTM= 40
    set @REPOLEVersion_90= 90

    set @REPOLEVersion_100= 100        

    set @REPOLEVersion_70RTM_string = N'70RTM'
    set @REPOLEVersion_70SP1_string = N'70SP1'
    set @REPOLEVersion_70SP2_string = N'70SP2'
    set @REPOLEVersion_70SP3_string = N'70SP3'
    set @REPOLEVersion_70SP4_string = N'70SP4'
    set @REPOLEVersion_80RTM_string = N'80RTM'
    set @REPOLEVersion_80SP1_string = N'80SP1'
    set @REPOLEVersion_80SP2_string = N'80SP2'
    set @REPOLEVersion_80SP3_string = N'80SP3'
    set @REPOLEVersion_90RTM_string = N'90RTM'
    set @REPOLEVersion_100RTM_string = N'100RTM'    


    /*
    ** Set the status to Active (1)
    */
    select @statid        = 1
    select @global        = 1
    select @push        = 0
    select @db_name        = DB_NAME()
    select @ad_guidname = NULL
    			,@publishingservername = publishingservername()

    /*
    ** Security Check
    */

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)
    
    -- Parameter check: @publication_compatibility_level: Allowed range.
    if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70RTM_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_70RTM
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP1_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_70SP1
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP2_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_70SP2
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP3_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_70SP2
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP4_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_70SP2
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80RTM_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_80RTM
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP1_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_80RTM
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP2_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_80RTM
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP3_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_80RTM
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_90RTM_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_90
    end
    else if UPPER(@publication_compatibility_level collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_100RTM_string
    begin
        select @pubcompat_level_id = @REPOLEVersion_100
    end    
    else 
    begin
        raiserror(21402, 16, -1, '@publication_compatibility_level')
        return (1)
    end

    if (@pubcompat_level_id  not in
            (
                @REPOLEVersion_70RTM,
                 @REPOLEVersion_70SP1,
                 @REPOLEVersion_70SP2,
                @REPOLEVersion_80RTM,
                @REPOLEVersion_90,
                @REPOLEVersion_100                
            )
        )
    begin
        raiserror(21402, 16, -1, '@publication_compatibility_level')
        return (1)
    end



    -- Parameter check: @publication_compatibility_level: A Katmai publication db can 
    -- only have Katmai compatible publications for the new data types.
    -- We will remove this constraint during the next phase of NewDateTime improvement
    -- yiche 12.7.2006
    if @REPOLEVersion_100 = @pubcompat_level_id and
       exists (select * from dbo.sysmergepublications where 
                   backward_comp_level < @REPOLEVersion_100)
    begin
        raiserror(21527, 16, -1, @publication, @db_name)
        return (1)
    end
    -- Parameter check: @publication_compatibility_level: A Yukon publication db can either have
    -- downlevel or Yukon compatible publications, but not both.
    else if @REPOLEVersion_90 = @pubcompat_level_id and
       exists (select * from dbo.sysmergepublications where 
                   backward_comp_level < @REPOLEVersion_90)
    begin
        raiserror(21527, 16, -1, @publication, @db_name)
        return (1)
    end
    else if @REPOLEVersion_90 > @pubcompat_level_id and
       exists (select * from dbo.sysmergepublications where 
                   backward_comp_level >= @REPOLEVersion_90)
    begin
        raiserror(21528, 16, -1, @publication, @db_name)
        return (1)
    end

    /*
    ** Parameter Check: @publication.
    ** The @publication name must conform to the rules for identifiers,
    ** and must not be the keyword 'all'.
    */
    exec @retcode = sys.sp_MSreplcheck_name @publication, '@publication', 'sp_addmergepublication'
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
       
    if LOWER (@publication) = 'all'
        begin
            raiserror (14034, 16, -1)
            return (1)
        end
            
    if @max_concurrent_merge<0
        begin
            raiserror(21402, 16, -1, '@max_concurrent_merge')
            return (1)
        end

    /*
    ** Parameter Check: @retention.
    */
    
    if @retention_period_unit is null
        or lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) not in ('day', 'days', 'dd', 'year', 'years', 'yy', 'yyyy', 'month', 'months', 'mm', 'week', 'weeks', 'wk', 'hour', 'hours', 'hh', 'minute', 'minutes', 'mi')
    begin
        raiserror(22527, 16, -1, @retention_period_unit)
        return 1
    end
    
    select @retention_period_unit_id = 
        case    when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('day', 'days', 'dd')
                    then 0
                when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('week', 'weeks', 'wk')
                    then 1
                when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('month', 'months', 'mm')
                    then 2
                when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('year', 'years', 'yy', 'yyyy')
                    then 3
                when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('hour', 'hours', 'hh')
                    then 4
                when lower(@retention_period_unit collate SQL_Latin1_General_CP1_CI_AS) in ('minute', 'minutes', 'mi')
                    then 5
        end
        
    if @retention_period_unit_id <> 0 and @pubcompat_level_id < @REPOLEVersion_90
    begin
        raiserror(22528, 16, -1, @publication)
        return 1
    end
    
    if @retention is NULL
    begin
        select @retention = 0
    end
    else if    @retention < 0 or @retention > sys.fn_units_until_maxdate(@retention_period_unit_id, getdate())
    begin
        raiserror(20050, 16, -1, 0)
        return(1)
    end

    /*
    ** Parameter Check: @conflict_retention.
    */
        
    if @conflict_retention is not NULL and @conflict_retention<0 
        begin
            raiserror(20050, 16, -1, 0)
            return(1)
        end

    /*
    ** if it is NULL, use the default value of 14 days.
    */
    if @conflict_retention is NULL 
        select @conflict_retention = 14

    /*
    ** Parameter Check: @sync_mode.
    ** Make sure that the sync_mode is one of the following:
    **
    **    id    sync_mode
    **    ==    ==========
    **     0    (bcp)native
    **     1    (bcp)character
    */
    
    if LOWER(@sync_mode collate SQL_Latin1_General_CP1_CS_AS)='portable' select @sync_mode='character'

    if LOWER(@sync_mode collate SQL_Latin1_General_CP1_CS_AS) is NULL OR LOWER(@sync_mode collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('bcp native', 'bcp character', 'native', 'character')
        begin
            raiserror (20076, 16, -1)
            return (1)
        end

    if LOWER(@sync_mode collate SQL_Latin1_General_CP1_CS_AS) = 'native' or 
       LOWER(@sync_mode collate SQL_Latin1_General_CP1_CS_AS)='bcp native' 
        select @sync_modeid = 0
    else 
        select @sync_modeid = 1
        
    if @retention_period_unit_id <> 0 and @sync_modeid = 1
    begin
        raiserror(22555, 16, -1, @publication)
        return 1
    end

    /*
    ** Parameter Check:     @allow_push.
    */

    if @allow_push IS NULL OR LOWER(@allow_push collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_push')
            RETURN (1)
        END

    if LOWER(@allow_push collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        select @allow_push_id = 1
    else 
        select @allow_push_id = 0

    /*
    ** Parameter Check:     @allow_pull.
    */

    if @allow_pull IS NULL OR LOWER(@allow_pull collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_pull')
            RETURN (1)
        END
    if LOWER(@allow_pull collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        select @allow_pull_id = 1
    else 
        select @allow_pull_id = 0

    /*
    ** Parameter Check:     @allow_anonymous.
    */

    if @allow_anonymous IS NULL OR LOWER(@allow_anonymous collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_anonymous')
            RETURN (1)
        END
    if LOWER(@allow_anonymous collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        select @allow_anonymous_id = 1
    else 
        select @allow_anonymous_id = 0
        
        
    if @generation_leveling_threshold is null
		set @generation_leveling_threshold=0
		
    if (@generation_leveling_threshold < 0)
    begin
		raiserror(21119, 16, -1, @generation_leveling_threshold, '@generation_leveling_threshold')
		return 1
	end

    /*
    ** Parameter Check:     @enabled_for_internet.
    */

    IF @enabled_for_internet IS NULL OR LOWER(@enabled_for_internet collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@enabled_for_internet')
            RETURN (1)
        END

    IF LOWER(@enabled_for_internet collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @enabled_for_internet_id = 1
    ELSE 
        SELECT @enabled_for_internet_id = 0

    /*
    ** Parameter Check: @conflict_logging, @centralized_conflicts.
    */

	-- Pick defaults based on pubcompat_level
	if @conflict_logging is null
	begin
		if @pubcompat_level_id < @REPOLEVersion_90
			set @conflict_logging = 'publisher'
		else
			set @conflict_logging = 'both'
	end
    
    if @centralized_conflicts is not null
    begin
        raiserror (21767, 10, 1, '@centralized_conflicts', '@conflict_logging')
    
        set @conflogging= 
                case LOWER(@centralized_conflicts collate SQL_Latin1_General_CP1_CS_AS)
                    when 'true' then 1
                    when 'false' then 0
                    else null
                end
    
        if @conflogging is null
        begin
            RAISERROR (14148, 16, -1, '@centralized_conflicts')
            RETURN (1)
        end
    end
    else if @conflict_logging is not null
    begin
        set @conflogging= 
                case LOWER(@conflict_logging collate SQL_Latin1_General_CP1_CS_AS)
                    when 'publisher' then 1
                    when 'subscriber' then 0
                    when 'both' then 2
                    else null
                end

        if @conflogging is null
        begin
            RAISERROR (14103, 16, -1, '@conflict_logging')
            RETURN (1)
        end
    end
    else
    begin
        RAISERROR (14103, 16, -1, '@conflict_logging')
        RETURN (1)
    end

    if @conflogging = 2 and 
       @pubcompat_level_id < @REPOLEVersion_90
    begin
        RAISERROR (20705, 16, -1, @publication)
        RETURN (1)
    end
    else if @conflogging = 0 and
            @pubcompat_level_id < @REPOLEVersion_70SP2
    begin
        raiserror(21349, 10, -1, @publication)
        set @pubcompat_level_id= @REPOLEVersion_70SP2
    end
    
    /*
    ** Parameter Check:     @dynamic_filter.
    */

    IF @dynamic_filters IS NULL OR LOWER(@dynamic_filters collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@dynamic_filters')
            RETURN (1)
        END

    IF LOWER(@dynamic_filters collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @dynamic_filters_id = 1
    ELSE 
        SELECT @dynamic_filters_id = 0

    if @validate_subscriber_info is not NULL
    begin
        if @dynamic_filters_id = 0
            begin
                raiserror(21313, 16, -1)
                return (1)
            end
    end
    else if @pubcompat_level_id >= @REPOLEVersion_90
		select @validate_subscriber_info = N''	-- Empty string = auto-detect. NULL = don't use the feature. 
												-- NULL is not available for new 90 compat publications any more.

    /*
    ** Parameter Check:     @allow_partition_realignment.
    */

    IF @allow_partition_realignment IS NULL OR LOWER(@allow_partition_realignment collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_partition_realignment')
            RETURN (1)
        END

    IF LOWER(@allow_partition_realignment collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @allow_partition_realignment_id = 1
    ELSE 
        SELECT @allow_partition_realignment_id = 0
        
    -- Portable snapshot
    IF @snapshot_in_defaultfolder IS NULL OR LOWER(@snapshot_in_defaultfolder collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@snapshot_in_defaultfolder')
        RETURN (1)
    END
    
    IF LOWER(@snapshot_in_defaultfolder collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        SELECT @snapshot_in_defaultfolder_bit = 1
    END
    ELSE
    BEGIN
        SELECT @snapshot_in_defaultfolder_bit = 0
    END

    -- Pre/Post snapshot commands
    -- If @sync_method is character mode bcp, this would indicate that
    -- this publication may support non-SQL Server subscribers. In this 
    -- case, pre- and post- snapshot commands are not allowed.
    IF @sync_modeid = 1 AND 
        ((@pre_snapshot_script IS NOT NULL AND @pre_snapshot_script <> N'' ) OR
         (@post_snapshot_script IS NOT NULL AND @post_snapshot_script <> N''))
    BEGIN
        RAISERROR (21151, 16, -1)
        RETURN (1)
    END

    -- Parameter check - @compress_snapshot
    -- @compress_snapshot can be 1 if @alt_snapshot_folder is non-null
    IF @compress_snapshot IS NULL OR LOWER(@compress_snapshot collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@compress_snapshot')
        RETURN (1)
    END
    
    IF LOWER(@compress_snapshot collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        SELECT @compress_snapshot_bit = 1
    END
    ELSE
    BEGIN
        SELECT @compress_snapshot_bit = 0
    END


    -- Only bump up the compatibility level if only a compressed snapshot
    -- is generated at the alternate snapshot folder
    if @snapshot_in_defaultfolder_bit = 0 and
       @compress_snapshot_bit = 1
    begin
        if @pubcompat_level_id < @REPOLEVersion_80RTM
        begin
            raiserror(21350, 10, -1, @publication)
            set @pubcompat_level_id= @REPOLEVersion_80RTM
        end
    end

    -- Snapshot compression can only be enabled if an alternate 
    -- snapshot generation folder exists.
    IF (@compress_snapshot_bit = 1 AND 
        (@alt_snapshot_folder IS NULL OR @alt_snapshot_folder = N''))
    BEGIN
        RAISERROR (21157, 16, -1)
        RETURN (1)
    END       

    -- Parameter check: ftp_address
    -- If the publication is enabled for internet, ftp_address cannot be null
    IF @enabled_for_internet_id = 1 AND (@ftp_address IS NULL OR @ftp_address = N'')
    BEGIN
        RAISERROR (21158, 16, -1)
        RETURN (1)
    END        

    -- Parameter check: ftp_port
    IF @ftp_port IS NULL OR @ftp_port < 0 OR @ftp_port > 65535
    BEGIN
        RAISERROR (21160, 16, -1)
        return 1
    END

    if @ftp_address IS not NULL and @ftp_address <> N''
    begin
        select @enabled_for_internet_id = 1
    end

    -- Encrypt ftp password before putting it into the dbo.sysmergepublications
    -- table if one is provided
    SELECT @enc_ftp_password = NULL
    IF @ftp_password IS NOT NULL
    BEGIN
        SELECT @enc_ftp_password = @ftp_password 
        EXEC @retcode = sys.sp_MSreplencrypt @enc_ftp_password OUTPUT
        IF @retcode <> 0
        BEGIN
            RETURN (1)
        END
    END       

    /*
    ** Parameter Check:     @keep_partition_changes.
    */

    if LOWER(@keep_partition_changes collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@keep_partition_changes')
            RETURN (1)
        END

    if LOWER(@keep_partition_changes collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        begin
            set @keep_before_values_int = 1
        end
    else 
        set @keep_before_values_int = 0

    /*
    ** Parameter Check:     @allow_subscription_copy_id.
    */

    if LOWER(@allow_subscription_copy collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_subscription_copy')
            RETURN (1)
        END
        
    IF LOWER(@allow_subscription_copy collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @allow_subscription_copy_id = 1
    ELSE 
        SELECT @allow_subscription_copy_id = 0
        
    /*
    ** Parameter Check:     @use_partition_groups.
    */
    
    if @use_partition_groups is not null and
                LOWER(@use_partition_groups collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@use_partition_groups')
        RETURN (1)
    END
        
    IF LOWER(@use_partition_groups collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @use_partition_groups_id = 2
    ELSE IF LOWER(@use_partition_groups collate SQL_Latin1_General_CP1_CS_AS) = 'false' 
        SELECT @use_partition_groups_id = 0
    ELSE
        SELECT @use_partition_groups_id = NULL    -- Let system decide whether it should be true or false.
        
    -- Keep-before-image functionality is not supported if partition id's are in use and backward
    -- compat level is 90 or higher.
    if @use_partition_groups_id = 2 and @pubcompat_level_id >= @REPOLEVersion_90
        and @keep_before_values_int = 1
    begin
        select @keep_before_values_int = 0
        --raiserror(21729, 16, -1)
    end

    /*
    ** Parameter Check:     @allow_synctoalternate_id.
    */

    if LOWER(@allow_synctoalternate collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_synctoalternate')
            RETURN (1)
        END
        
    IF LOWER(@allow_synctoalternate collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @allow_synctoalternate_id = 1
    ELSE 
        SELECT @allow_synctoalternate_id = 0
        
    if LOWER(@allow_web_synchronization collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, '@allow_web_synchronization')
            RETURN (1)
        END
        
    IF LOWER(@allow_web_synchronization collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @allow_web_synchronization_id = 1
    ELSE 
        SELECT @allow_web_synchronization_id = 0
    /*
    ** Parameter Check: @max_concurrent_dynamic_snapshots
    */
    
    if @max_concurrent_dynamic_snapshots < 0 or @max_concurrent_dynamic_snapshots is null
    begin
        raiserror(21403, 16, -1)
        return (1)
    end
        
    /*
    ** Parameter Check:     @allow_subscriber_initiated_snapshot
    */

    if LOWER(@allow_subscriber_initiated_snapshot collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@allow_subscriber_initiated_snapshot')
        RETURN (1)
    END
        
    IF LOWER(@allow_subscriber_initiated_snapshot collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
        SELECT @allow_subscriber_initiated_snapshot_id = 1
    ELSE 
        SELECT @allow_subscriber_initiated_snapshot_id = 0

    /*
    ** Parameter Check:     @replicate_ddl
    */
    -- the default for @replicate_ddl is NULL. Choose a default of 0 or 1 based on the pub compat level
    if @replicate_ddl is NULL
    begin
        if @pubcompat_level_id < @REPOLEVersion_90
            select @replicate_ddl = 0
        else
            select @replicate_ddl = 1
    end
    else
    begin
        if @replicate_ddl <> 0 and @pubcompat_level_id < @REPOLEVersion_90
        begin
            RAISERROR (20650, 16, -1, @publication)
            RETURN (1)
        end
        if @replicate_ddl > 1
            select @replicate_ddl = 1
    end

    /*
    ** Check to see if the publication name is already used.
    ** 1. check merge pubs
    ** 2. check online publications
    */
    if exists (select * from dbo.sysmergepublications 
        where name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name())
    begin
        RAISERROR (20025, 16, -1, @publication)
        RETURN (1)
    end

    if (select category & @tranpublish_bit from master.dbo.sysdatabases where name = @db_name collate database_default) <> 0
    begin
        EXEC @retcode = sys.sp_helppublication @publication, @found output

        if @@ERROR <> 0 OR @retcode <> 0
        BEGIN
            RETURN (1)
        END

        if @found <> 0 
        BEGIN
            RAISERROR (20025, 16, -1, @publication)
            RETURN (1)
        END
    end


    /*
    **    Add the publication as the designmaster of the replica set.
    */

    /* Generate a guid for the publication ID */
    set @pubid = newid()

    /* Look for existing nickname from any other subscription */
    exec @retcode= sys.sp_MSgetreplnick NULL, NULL , NULL,    @replnick out
    if (@@error <> 0) or @retcode <> 0 
    begin
        RETURN(1)
    end

    /* Generate a new replica nickname from the @pubid */
    if (@replnick is null)
    begin
        execute @retcode = sys.sp_MSgenreplnickname 
                                @srcguid= @pubid, 
                                @replnick= @replnick output, 
                                @compatlevel= @pubcompat_level_id
        IF @@ERROR <>0 OR @retcode <> 0
        BEGIN
            RAISERROR (20077, 16, -1)
            RETURN (1)
        END
    end
    else
    begin
        -- if replnick is not null it means that this is a republisher
        -- check to see if there are any anonymous or local subscriptions
        if exists (select 1 from dbo.sysmergesubscriptions  
                    where db_name=@db_name and 
                          UPPER(subscriber_server) collate database_default = UPPER(publishingservername()) collate database_default and
                          subscriber_type > 1 and
                          status <> 7) -- REPLICA_STATUS_BeforeRestore
        begin
            RAISERROR(21087, 16, -1)
            return (1)
        end

        -- check to see if there are global subscriptions with prority 0
        select @priority=max(priority) from dbo.sysmergesubscriptions 
            where db_name=@db_name and 
                  UPPER(subscriber_server) collate database_default = UPPER(publishingservername()) collate database_default and
                  status <> 7 -- REPLICA_STATUS_BeforeRestore
        if @priority = 0 
        begin
            RAISERROR(21091, 16, -1)
            return (1)
        end
    end
    

    /*
    ** Get distributor information
    */    
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT
                            ,@distributor = @distservername OUTPUT
                            ,@distribdb = @distribdb OUTPUT
                            ,@working_directory = @working_directory OUTPUT
    if @@error <> 0 OR @retcode <> 0 or @distributor IS NULL OR @distribdb IS NULL or @working_directory is null
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END
    
    /*
    **    add an entry into dbo.sysmergepublications
    */
    begin tran      
    save tran sp_addmergepublication
    
        exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                      @lockowner = N'Transaction'
        if @retcode<>0 or @@error<>0
        begin
            raiserror(20713, 16, -1, 'sp_addmergepublication', @publication)
            goto FAILURE            
        end

        select @got_merge_admin_applock = 1
        
        /* Add row in the publications table */
        insert dbo.sysmergepublications
            (pubid, 
            name, 
            description, 
            designmasterid, 
            retention, 
            parentid, 
            sync_mode, 
            allow_push, 
            allow_pull, 
            allow_anonymous, 
            centralized_conflicts,
            decentralized_conflicts,
            status,
            snapshot_ready,
            enabled_for_internet,
            publication_type,
            dynamic_filters,
            snapshot_in_defaultfolder,
            alt_snapshot_folder,
            pre_snapshot_script,
            post_snapshot_script,
            compress_snapshot,
            ftp_address,
            ftp_port,
            ftp_subdirectory,
            ftp_login,
            ftp_password,
            conflict_retention,
            keep_before_values,
            allow_subscription_copy,
            allow_synctoalternate,
            validate_subscriber_info,
            ad_guidname,
            backward_comp_level,
            max_concurrent_merge,
            max_concurrent_dynamic_snapshots,
            use_partition_groups,
            replicate_ddl,
            allow_subscriber_initiated_snapshot,
            distributor,
            allow_web_synchronization,
            web_synchronization_url,
            allow_partition_realignment,
            retention_period_unit,
            generation_leveling_threshold,
            automatic_reinitialization_policy)
        values
            (@pubid, 
            @publication, 
            @description, 
            @pubid, 
            @retention, 
            @pubid, 
            @sync_modeid, 
            @allow_push_id, 
            @allow_pull_id, 
            @allow_anonymous_id, 
            case @conflogging -- centralized
                when 1 then 1
                when 2 then 1
                else 0
            end,
            case @conflogging -- decentralized
                when 1 then 0
                when 2 then 1
                else 1
            end,
            @statid,
            @false,
            @enabled_for_internet_id,
            @full,
            @dynamic_filters_id,
            @snapshot_in_defaultfolder_bit,
            @alt_snapshot_folder,
            @pre_snapshot_script,
            @post_snapshot_script,
            @compress_snapshot_bit,
            @ftp_address,
            @ftp_port,
            @ftp_subdirectory,
            @ftp_login,
            @enc_ftp_password,
            @conflict_retention,
            @keep_before_values_int,
            @allow_subscription_copy_id,
            @allow_synctoalternate_id,
            @validate_subscriber_info,
            @ad_guidname, 
            @pubcompat_level_id,
            @max_concurrent_merge,
            @max_concurrent_dynamic_snapshots,
            @use_partition_groups_id,
            @replicate_ddl,
            @allow_subscriber_initiated_snapshot_id,
            @distservername,
            @allow_web_synchronization_id,
            @web_synchronization_url,
            @allow_partition_realignment_id,
            @retention_period_unit_id,
            @generation_leveling_threshold,
            @automatic_reinitialization_policy)
        if @@ERROR <> 0
            begin
                goto FAILURE
            end

        /* Add row to represent reciprocal subscription */                
        INSERT dbo.sysmergesubscriptions (subscriber_server, db_name, pubid, datasource_type,
                subid, replnickname, replicastate, status, subscriber_type, subscription_type,
                sync_type, description, priority, last_validated, replica_version)
        VALUES (publishingservername(), @db_name, @pubid, 0, 
                @pubid, @replnick, newid(), @statid, @global, @push,
                @automatic, @description, @priority, getdate(), 90)
        if @@ERROR <> 0
            begin
                goto FAILURE
            end
        /*
        **    Add row for merge publication to dbo.MSmerge_replinfo.
        */
        insert dbo.MSmerge_replinfo(repid, login_name)
            values (@pubid, suser_sname(suser_sid()))
        if @@ERROR <> 0
            begin
                goto FAILURE
            end


        /*
        ** Add the publication to the distributor side
        */
        SELECT @distpubid = @replnick
        
        declare @publisher_engine_edition int

        select @publisher_engine_edition = sys.fn_MSrepl_editionid()

        select @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + 
            '.dbo.sp_MSadd_publication'
        EXECUTE @retcode = @distproc
            @publisher = @publishingservername,
            @publisher_db = @db_name,
            @publication = @publication,
            --@publication_id = NULL,
            @publication_type = 2,            -- 0 = Trans, 1 = Snapshot, 2 = Merge
            @independent_agent = @true,
            @immediate_sync = @true,
            @allow_push = @allow_push_id,
            @allow_pull = @allow_pull_id,
            @allow_anonymous = @allow_anonymous_id,
            @description = @description,
            @retention = @retention,
            @allow_subscription_copy = @allow_subscription_copy_id,
            @retention_period_unit = @retention_period_unit_id,
            @publisher_engine_edition = @publisher_engine_edition

        IF @@ERROR <> 0 or @retcode <> 0
            BEGIN
                GOTO FAILURE
            END
                
        -- Populate the initial list.
        exec @retcode = sys.sp_grant_publication_access 
            @publication = @publication,
            @login = null,
            @reserved = 'init'
        IF @@error <> 0 OR @retcode <> 0
            GOTO FAILURE

        
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    commit tran

    return (0)

FAILURE:
    RAISERROR (14018, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION sp_addmergepublication
        COMMIT TRANSACTION
    end
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_addmergepublication] TO [public] AS [dbo]
GO
