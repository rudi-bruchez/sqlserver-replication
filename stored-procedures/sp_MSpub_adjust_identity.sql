SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpub_adjust_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpub_adjust_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpub_adjust_identity]
	@artid [int],
	@max_identity [bigint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode int
            ,@cmd nvarchar(1000)
            ,@objid int, @threshhold int
            ,@pub_range bigint, @next_seed bigint, @current_pub_range bigint
            ,@last_seed bigint, @identity_so_far bigint, @threshold int, @range bigint
            ,@database sysname, @table_name sysname
            ,@qualname nvarchar(517)
            ,@distributor sysname
            ,@distribdb sysname
            ,@publishingservername sysname

    --
    -- Security Check.
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
        
    	--noop if no updatable subscription needauto-identity range management
	if not exists(
        SELECT art1.objid
          FROM sysarticles art1,
               sysarticleupdates art2
          where art1.artid = art2.artid and
                art2.identity_support = 1 and
                (art1.artid = @artid or @artid is null) and
                ObjectProperty(art1.objid, 'TableHasIdentity') = 1)
         return (0)
               
    
    select @database = db_name()
			,@publishingservername = publishingservername()
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
                                       @distribdb = @distribdb OUTPUT
    IF @@ERROR <> 0
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END

    DECLARE adjust_identity CURSOR LOCAL FAST_FORWARD FOR
        SELECT art1.objid
          FROM sysarticles art1,
               sysarticleupdates art2
          where art1.artid = art2.artid and
                art2.identity_support = 1 and
                (art1.artid = @artid or @artid is null) and
                ObjectProperty(art1.objid, 'TableHasIdentity') = 1 
   FOR READ ONLY

    OPEN adjust_identity        
    FETCH adjust_identity INTO @objid
    WHILE (@@fetch_status <> -1)
    begin
        select @table_name = object_name(@objid)
        exec @retcode = sys.sp_MSget_qualified_name @objid, @qualname OUTPUT
        
        select @range = range, @pub_range = pub_range, @current_pub_range = current_pub_range, 
            @last_seed = last_seed, 
            @threshold = threshold from 
            MSpub_identity_range where objid=@objid
  
        select @identity_so_far = isnull(ident_current(@qualname), ident_seed(@qualname))

        if @last_seed is null
        begin
            -- First time
            select @last_seed = (@identity_so_far / @pub_range) * @pub_range
            -- We always reserve a new range for the publisher without reseeding 
            -- the publisher, and we guarantee to have more slots then 
            -- a full range initially for the publisher.
            if  (@pub_range > 0 and @last_seed < @identity_so_far) or
                (@pub_range < 0 and @last_seed > @identity_so_far)
                select @last_seed = @last_seed + @pub_range

            select @next_seed = @last_seed + @pub_range
            -- Initialize distribution side entry
            SELECT @cmd = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSinsert_identity'
            EXEC @retcode = @cmd
                @publisher = @publishingservername,
                @publisher_db = @database,
                @tablename = @table_name,
                @identity_support = 1,
                @pub_identity_range = 0, -- We don't need this at the distributor
                @identity_range = @range,
                @threshold  = @threshold,
                -- Make sure we don't have gap at the beginning
                @next_seed  = @next_seed,
                @max_identity = @max_identity
            IF @@ERROR <> 0 OR @retcode <> 0
                GOTO UNDO
            -- Add constraint only without reseeding.
            exec @retcode = sys.sp_MSreseed
                @objid = @objid,
                @next_seed = @last_seed,
                @range = @pub_range,
                @is_publisher = -1,
                @check_only = 1,
                @initial_setting = 1,
                @bound_value = @identity_so_far

            IF @@ERROR <> 0 OR @retcode <> 0
                GOTO UNDO
            update MSpub_identity_range set last_seed = @last_seed where objid = @objid
            IF @@ERROR <> 0
                GOTO UNDO
        end
        else
        begin

            -- Leave one slot unused. This is to prevent violation of primary key constraint
            -- if the next value is used by a subscriber and the publisher has received it.
            -- It seems the pk constraint will be validated before this check.
            declare @actual_range int
            if @current_pub_range > 0
                select @actual_range = @current_pub_range -1
            else
                select @actual_range = @current_pub_range +1

            -- Calculate the current ratio
            if 100*(@identity_so_far - @last_seed)/@actual_range >= @threshold
            -- need bump up
            begin
                SELECT @cmd = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSfetchAdjustidentityrange'
                EXEC @retcode = @cmd
                    @publisher = @publishingservername,
                    @publisher_db = @database,
                    @tablename = @table_name,
                    @adjust_only = 1,
                    @for_publisher = 1,
                    @range = @pub_range,
                    @next_seed = @next_seed output
                IF @@ERROR <> 0 OR @retcode <> 0
                    GOTO UNDO

                select @last_seed = @next_seed - @pub_range
                
                update MSpub_identity_range set last_seed = @last_seed,
                    current_pub_range = @pub_range
                    where objid = @objid
                IF @@ERROR <> 0
                    GOTO UNDO
                -- RESEED and change constraint
                exec @retcode = sys.sp_MSreseed
                    @objid = @objid,
                    @next_seed = @last_seed,
                    @range = @pub_range,
                    @is_publisher = -1
                IF @@ERROR <> 0 OR @retcode <> 0
                    GOTO UNDO
            end
        end

        FETCH adjust_identity INTO @objid
    end
    return 0
UNDO:
    -- No need to start a transaction.
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpub_adjust_identity] TO [public] AS [dbo]
GO
