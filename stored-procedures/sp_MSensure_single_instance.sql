SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSensure_single_instance]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSensure_single_instance] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSensure_single_instance]
	@application_name [sysname],
	@agent_type [int]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON

    DECLARE @retcode     int,
            @type         sysname,
            @dbprincipal sysname

    if @agent_type = 4 and exists (select 1 from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
    begin
        -- for merge any pal user (PAL of any publication) can do the instance check
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
        if (@retcode <> 0) or (@@error <> 0)
            return 1

        -- use the merge pal role for merge  
        select @dbprincipal = N'MSmerge_PAL_role'
    end
    else
    begin
        IF IS_MEMBER('db_owner') != 1
        BEGIN
            -- "Only members of the sysadmin or db_owner roles can perform this operation."
            RAISERROR(21050, 14, -1)
            RETURN 1
        END

        -- use db_owner principal
        select @dbprincipal = N'db_owner'        
    end

    IF @agent_type = 1
    BEGIN 
        SELECT @type = 'snapshot'
    END
    ELSE IF @agent_type = 2
    BEGIN
        SELECT @type = 'logreader'
    END
    ELSE IF @agent_type = 9
    BEGIN
        SELECT @type = 'queuereader'
    END
    ELSE IF @agent_type = 10
    BEGIN
        SELECT @type = 'distribution'
    END
    ELSE IF @agent_type = 4
    BEGIN
        SELECT @type = 'merge'
    END
    ELSE
    BEGIN
        -- "Invalid value given for parameter @type."
        RAISERROR(15021, 16, -1, '@type')
        RETURN 1
    END
    
    -- get an applock at the db_owner level to ensure we 
    -- only allow one agent to run at a time. only dbo
    -- for the distribution db will be able to aquire this
    EXEC @retcode = sys.sp_getapplock @Resource = @application_name, 
                                      @LockMode = 'Exclusive', 
                                      @LockOwner = 'Session',
                                      @LockTimeout = 0,
                                      @DbPrincipal = @dbprincipal
    IF @@ERROR <> 0 OR @retcode NOT IN (0, 1)
    BEGIN
        -- "Another '@type' agent for the subscription(s) is running or the server is working on a previous request by the same agent."
        RAISERROR(21036, 16, -1, @type)
        RETURN 1
    END

    -- Select the name of the server this executes on if the physical server name is not the same as the virtual server name
    if lower(@@servername) <> lower(publishingservername())
        select @@servername
    else
        select NULL
        
    RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSensure_single_instance] TO [public] AS [dbo]
GO
