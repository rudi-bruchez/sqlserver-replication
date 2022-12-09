SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changesubscriptiondtsinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changesubscriptiondtsinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changesubscriptiondtsinfo]
	@job_id [varbinary](16),
	@dts_package_name [sysname],
	@dts_package_password [sysname],
	@dts_package_location [nvarchar](12)
WITH EXECUTE AS CALLER
AS
/*
    ** Declarations.
    */

    DECLARE @srvid smallint
    DECLARE @artid int
    DECLARE @retcode int
    declare @login_name sysname
    declare @update_mode int
    declare @subscription_type int
    declare @dts_package_location_id int

    /*
    ** Initializations.
    */
    SET NOCOUNT ON
    
    
    /* 
    ** Get subscription properties and do Security Check.
    ** We use login_name stored in syssubscriptions to manage security 
    */

    select @update_mode = update_mode, @login_name = login_name,
        @subscription_type = subscription_type,
        @artid = artid              
        FROM syssubscriptions s WHERE 
            s.distribution_jobid = @job_id

    /*
    ** Check if the subscription exists.
    */
    IF @update_mode is null
    BEGIN
        RAISERROR (14055, 11, -1)
        RETURN (1)
    END

    if  @update_mode != 0
    begin
        RAISERROR(21180, 16, -1)    
        RETURN (1)
    end

    -- Only push store DTS info at distributor.
    if @subscription_type <> 0
    begin
        RAISERROR(21181, 16, -1)    
        RETURN (1)
    end

    --Security check

    IF  suser_sname(suser_sid()) <> @login_name AND is_srvrolemember('sysadmin') <> 1  
        AND is_member ('db_owner') <> 1
    BEGIN
        -- Only members of the sysadmin fixed server role, db_owner fixed database role or the creator of the subscription can change this subscription property.'
        RAISERROR(21175, 11, -1)
        RETURN (1)
    END

    -- Get pubid
    declare @pubid int
    select @pubid = pubid from sysarticles where artid = @artid

    /* Get subscription type of the publication */
    if not exists (select * from syspublications where
        pubid = @pubid and
        allow_dts = 1)
    begin
        RAISERROR(21178, 16, -1)    
        RETURN (1)
    end

    if @dts_package_location is null
        select @dts_package_location_id = null
    else IF LOWER(@dts_package_location collate SQL_Latin1_General_CP1_CS_AS) = N'distributor' 
        select @dts_package_location_id = 0
    ELSE IF LOWER(@dts_package_location collate SQL_Latin1_General_CP1_CS_AS) = N'subscriber' 
        select @dts_package_location_id = 1
    ELSE 
    begin
        raiserror(20587, 16, -1, '@dts_package_location', 'sp_changesubscriptiondtsinfo')
        return(1)
    end

    -- Encrypt DTS package password
    declare @change_password bit

    if @dts_package_password is null
        select @change_password = 0
    else
    begin
    	IF RTRIM(@dts_package_password) = N''
    	BEGIN
    		-- Use of DTS packages in replication requires a non-NULL/non-empty string password. Specify a valid value for parameter '%s'.
			RAISERROR(21732,16, -1, '@dts_package_password')
			RETURN 1
    	END

        select @change_password = 1
	end
	
    -- When user sends in empty string, reset it to null.
    -- Have to do this before scramble because the result may contains invalid
    -- unicode code points which are equael to some collation.
    if @dts_package_password = N''
        select @dts_package_password = NULL

    declare @enc_dts_package_password nvarchar(524)
        select @enc_dts_package_password = @dts_package_password

    if @enc_dts_package_password is not null
    begin
        EXEC @retcode = sys.sp_MSreplencrypt @enc_dts_package_password OUTPUT
        IF @@error <> 0 OR @retcode <> 0
            return 1
    end

    /*
    ** Get distribution server information for remote RPC
    ** agent verification.
    */
    declare @distributor sysname
    declare @distribdb sysname
    declare @distproc nvarchar(1000)

    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
        @distribdb = @distribdb OUTPUT

    IF @@error <> 0 OR @retcode <> 0
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END

    /*
    ** Call proc to change the distributor
    */
    SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + 
        '.dbo.sp_MSchange_subscription_dts_info'

    exec @retcode = @distproc 
        @job_id = @job_id,
        @dts_package_name = @dts_package_name,
        @dts_package_password = @enc_dts_package_password,
        @dts_package_location = @dts_package_location_id,
        @change_password = @change_password

    IF @@error <> 0 OR @retcode <> 0
        RETURN (1)

    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_changesubscriptiondtsinfo] TO [public] AS [dbo]
GO
