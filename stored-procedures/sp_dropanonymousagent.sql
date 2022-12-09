SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropanonymousagent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropanonymousagent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropanonymousagent]
	@subid [uniqueidentifier],
	@type [int]
WITH EXECUTE AS CALLER
AS
set nocount on 
    declare @login sysname
    -- Null @login indicates sysadmin or db_owner
    if IS_SRVROLEMEMBER ('sysadmin') = 0 and is_member('db_owner') = 0
        select @login = suser_sname()
    /*
    ** Get distribution server information for remote RPC
    ** agent verification.
    */
    declare @distributor sysname
    declare @distribdb sysname
    declare @distproc nvarchar(1000)
    declare @retcode int

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
        '.dbo.sp_MSdrop_anonymous_entry'

    exec @retcode = @distproc 
        @subid = @subid,
        @login = @login,
        @type = @type

    IF @@error <> 0 OR @retcode <> 0
        RETURN (1)

    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_dropanonymousagent] TO [public] AS [dbo]
GO
