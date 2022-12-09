SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_is_snapshot_required]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_is_snapshot_required] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_is_snapshot_required]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [int],
	@schemaversion [bigint],
	@run_at_subscriber [bit]
WITH EXECUTE AS CALLER
AS
begin 
    set nocount on
    
    -- constants
    declare @READY                tinyint
    declare @NOT_READY            tinyint
    declare @INACTIVE            tinyint
    declare @ACTIVE                tinyint
    declare @ATTACHED            tinyint
    declare @DELETED            tinyint
    declare @PUSH                tinyint    
    declare @PULL                tinyint
    declare @ANONYMOUS            tinyint
    declare @LIGHTWEIGHT        tinyint
    declare @NOSYNC                tinyint
    declare @NOT_NEEDED            tinyint
    declare @NEEDED                tinyint
    declare @UNKNOWN            tinyint    
    declare @SCHEMA_REINIT_ALL    tinyint
    declare @SCHEMA_REINIT_UPLD    tinyint

    -- local vars
    declare @retcode            int
    declare @pubid                uniqueidentifier
    declare @subid                uniqueidentifier
    declare @status                tinyint
    declare @snapshot_ready        tinyint
    declare @sync_type            tinyint
    declare @recgen                bigint
    declare @recguid            uniqueidentifier
    declare @sentgen            bigint
    declare @sentguid            uniqueidentifier
    declare @schema_version        bigint
    declare @is_needed            int        -- flag to be selected prior to exit
                                        -- 0 not needed 1 needed 2 unknown
    select @READY                = 1
    select @NOT_READY            = 0
    select @INACTIVE            = 0
    select @ACTIVE                = 1
    select @DELETED                = 2
    select @ATTACHED            = 4
    select @PUSH                = 0
    select @PULL                = 1
    select @ANONYMOUS            = 2
    select @LIGHTWEIGHT         = 3
    select @NOSYNC                = 2
    select @NOT_NEEDED            = 0
    select @NEEDED                = 1
    select @UNKNOWN                = 2
    select @SCHEMA_REINIT_ALL     = 12 
    select @SCHEMA_REINIT_UPLD    = 14 

    select @retcode                = 0    
    select @pubid                = null
    select @subid                = null
    select @status                = null
    select @snapshot_ready        = null
    select @schema_version        = 0
    select @is_needed            = @UNKNOWN

    -- Security check
    if @run_at_subscriber = 0
    begin
        exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
        if @@error<>0 or @retcode<>0
        begin
            return 1
        end
    end
    else
    begin
        exec @retcode = sys.sp_MSreplcheck_subscribe    
        if @@error<>0 or @retcode<>0
        begin
            return 1
        end
    end


    -- Parameter Validation
    if @publisher is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publisher', 'sp_MSmerge_is_snapshot_required')
        return (1)
    end

    if @publisher_db is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publisher_db', 'sp_MSmerge_is_snapshot_required')
        return (1)
    end
    
    if @publication is null
    begin
        -- The parameter %s cannot be NULL.
        raiserror (14043, 16, -1, '@publication', 'sp_MSmerge_is_snapshot_required')
        return (1)
    end

    if @subscription_type not in (@PUSH, @PULL, @ANONYMOUS, @LIGHTWEIGHT)
    begin
        raiserror(20587, 16, -1, @subscription_type, 'sp_MSmerge_is_snapshot_required')
        return (1)
    end
    
    -- set schema_version if not already set
    if @schemaversion is null
    begin
        select @schemaversion = 0x00
    end
                
    -- Check to see if we have these tables. These tables will not exist
    -- on an uninitialized push subscription or a nonexistant publication. 
    if object_id('dbo.sysmergepublications', 'U') is null
        or object_id('dbo.sysmergesubscriptions', 'U') is null
        or object_id('dbo.MSmerge_replinfo', 'U') is null
    begin
        -- nonexistant publication or a pull/anon cases will 
        -- fall here and we have a check after this block
        select @pubid    = null
        select @subid    = null
        select @status     = null
    end
    -- else we will retrieve the information from the tables
    else
    begin
        select @snapshot_ready    = smp.snapshot_ready,
                @pubid             = sms.pubid,
                @subid            = sms.subid,
                @sync_type        = sms.sync_type,
                @status         = sms.status,
                @schema_version    = sms.schemaversion
            from dbo.sysmergepublications smp,
                 dbo.sysmergesubscriptions sms
            where LOWER(smp.publisher)  = LOWER(@publisher)
                and smp.publisher_db         = @publisher_db
                and smp.name                = @publication
                and sms.pubid                = smp.pubid
                and sms.db_name                = @subscriber_db
                and sms.subscription_type    = @subscription_type
                and LOWER(sms.subscriber_server)    = LOWER(@subscriber)
    end

    -- check for valid publication and subscription
    --
    -- NOTE:
    --     Since this proc is run via activex and we must call initialize prior to running this proc
    --     the checks below are unnecessary. A user will fail before calling the proc if any of these
    --    values are null. We may want to consider removing this in the future. We will leave this
    --     here for now as extra protection.
    if @pubid is null
        or @subid is null
        or @status is null
    begin
        -- if we are at the subscriber then the sub does not exist
        if @run_at_subscriber = 1 
        begin
            -- if we are running on a push subscriber and tables are missing then  
            -- we will say that we just don't know whether a snap is needed. There
            -- are two possibilities in this case. 1) Subscription does not exist.
            -- 2) Subscription has not been initialized. Result = UKNOWN.
            if @subscription_type = @PUSH
            begin
                -- set to unknown and then return
                select @is_needed = @UNKNOWN
                goto Results_Handler
            end
            else
            begin
                -- The subscription on the Subscriber does not exist.
                raiserror (20017, 16, -1)
                return (1)
            end
        end
        -- for push and pull we will do some extra checking. Anonymous
        -- subscription info will never exist on publisher so we skip them
        else if @subscription_type in (@PULL, @PUSH) 
        begin
            -- if the subid or status is set to 
            -- null then the sub can not be found 
            if @subid is null 
                or @status is null
            begin
                -- The subscription could not be found.
                raiserror(20021, 16, -1)
                return (1)
            end            
            -- else we could not find the publication
            else 
            begin
                -- The publication '%s' does not exist.
                raiserror(20026, 16, -1, @publication)
                return (1)
            end
        end
    end

    -- check the no sync case first
    if @sync_type = @NOSYNC
    begin
        select @is_needed = @NOT_NEEDED
        goto Results_Handler    
    end
    
    -- if status is inactive or snapshot is not ready then we know that 
    -- the snapshot is needed if not then we have a bit more work to do
    if @status = @INACTIVE 
        or @snapshot_ready = @NOT_READY
        or (@schema_version = 0 and @subscription_type = @PUSH)
        or (@schema_version = -1 and @subscription_type = @PULL)
        or (@schema_version is null)
    begin
        select @is_needed = @NEEDED
        goto Results_Handler            
    end
    
    -- Subscriber specific queries
    if @run_at_subscriber = 1
    begin
        -- retrieve replinfo to see if we have been reinitialized. A reinitalized 
        -- subscription will have nulls for recgen, recguid, sentgen, sentguid. Here
        -- we check to see if it is not needed (if we find one row without null)
        if (@subscription_type = 3) -- light weight subscription does not store a sentgen and sentguid
        begin
            if @subid is not null and 
               @pubid is not null and 
               exists (select * from dbo.sysmergesubscriptions 
                        where pubid = @pubid and subid = pubid and recgen is not null and recguid is not null)
            begin
                select @is_needed = @NOT_NEEDED
            end
            -- else we definetly need a snapshot
            else
            begin
                select @is_needed = @NEEDED
            end
        end
        else
        begin
            if @subid is not null and 
               @pubid is not null and 
               exists (select * from dbo.sysmergesubscriptions 
                        where pubid = @pubid and subid = pubid and recgen is not null and recguid is not null and sentgen is not NULL and sentguid is not NULL)
            begin
                select @is_needed = @NOT_NEEDED
            end
            -- else we definetly need a snapshot
            else
            begin
                select @is_needed = @NEEDED
            end
        end
        goto Results_Handler
    end
    -- else if we are at the publisher then we must look for the pubwide reinit case 
    -- the only place we can look for this answer is the dbo.sysmergeschemachange table
    else
    begin
        if exists (select * 
                    from dbo.sysmergeschemachange 
                    where pubid = @pubid
                        and schemaversion > @schemaversion
                        and schematype in (@SCHEMA_REINIT_ALL, 
                                            @SCHEMA_REINIT_UPLD))
        begin
            select @is_needed = @NEEDED    
        end
        else
        begin
            select @is_needed = @NOT_NEEDED    
        end
        
        goto Results_Handler
    end

Results_Handler:
    -- set the is_snapshot_required val and leave the rest as null we  
    -- must have the other columns because tran and merge share the 
    -- agent code that processes the results of this stored proc.
    select "is_snapshot_required" = @is_needed,
            "schema_version"    = @schema_version
            
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_is_snapshot_required] TO [public] AS [dbo]
GO
