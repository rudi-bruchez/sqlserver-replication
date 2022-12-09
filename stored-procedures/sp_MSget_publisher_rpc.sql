SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_publisher_rpc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_publisher_rpc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_publisher_rpc]
	@trigger_id [int],
	@connect_string [nvarchar](2000) OUTPUT,
	@owner [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    declare @publisher sysname
                ,@publisher_db sysname
                ,@login sysname
                ,@password nvarchar(524)
                ,@security_mode int
                ,@object_id int
                ,@retcode int
                ,@islocalpublisher bit  -- 1 = local, 0 = remote

    --
    -- Make sure this proc is called from the trigger.
    -- Better to use object_id if owner name is passed in.
    --
    if trigger_nestlevel(@trigger_id) = 0
    begin
        raiserror(14126, 16, -1)
        return (1) -- current user does not have insert permission to underlying table
    end
    --
    -- Security check: the caller of this SP has to be one of the 
    -- predefined replication triggers defined in the db
    --
    if (@owner is null)
    begin
        if (@trigger_id not in (select object_id(object_name) 
                from dbo.MSreplication_objects
                where object_type = 'T'))
        begin
            raiserror(14126, 16, 4)
            return -1
        end
    end
    else
    begin
        if (@trigger_id not in (select object_id(quotename(@owner) + N'.' + quotename(object_name)) 
                from dbo.MSreplication_objects
                where object_type = 'T'))
        begin
            raiserror(14126, 16, 4)
            return -1
        end
    end
    --
    -- Get the security information
    --
    IF object_id('MSsubscription_properties' ,'U') is not NULL
    begin
        --
        -- MSsubscription_properties exists
        -- Check for the subscription
        --
        select @login = p.publisher_login,
                @password = p.publisher_password,
                @security_mode = p.publisher_security_mode,
                @publisher = o.publisher,
                @publisher_db = o.publisher_db
        from MSsubscription_properties p join MSreplication_objects o
            on (UPPER(p.publisher) = UPPER(o.publisher) 
                and p.publisher_db = o.publisher_db
                and p.publication = o.publication)
        where o.object_name = object_name(@trigger_id) 
        if (@security_mode is null or @security_mode = -1)
        begin
            --
            -- entry for the subscription does not exist
            -- or, sp_link_publication has not been called
            --
            raiserror(21079, 16, -1)
            return(1)
        end
    end
    else
    begin
        --
        -- MSsubscription_properties does not exist
        --
        raiserror(21079, 16, -1)
        return(1)
    end
    --
    -- if we have come this far - the subscription exists
    --
    select @islocalpublisher = case when (UPPER(@publisher) = UPPER(publishingservername())) then 1 else 0 end
    --
    -- Process based on security mode
    --
    if @security_mode = 2 -- 2 = use dbo.sysservers
    begin
        --
        -- we will be using linked/remote/local server entry
        -- send NULL connect_string - the trigger will just
        -- issue a RPC call to publisher
        --
        select @connect_string = null
    end
    else
    begin
        --
        -- we will be using specific login credential
        --
        if (@islocalpublisher = 1)
        begin
            --
            -- the publisher and subscriber are on the same server.
            -- OpenDataSource() fails to do loopback distributed RPC.
            -- We will override the settings of security mode = 0
            -- and send back a NULL connect string - a LOCAL Proc execution
            -- will occur.
            --
            select @connect_string = null
        end
        else
        begin
            --
            -- publisher and subscriber on different server
            --
            if @login is null
            begin
                --
                -- Cannot have null login
                --
                raiserror(21079, 16, -1)
                return(1)
            end
            --
            -- verify the password
            --
            EXEC @retcode = sys.sp_MSrepldecrypt @password OUTPUT
            IF @@error <> 0 OR @retcode <> 0
            begin
                --
                -- password verification failed
                --
                return 1
            end
            if @password is null
                select @password = N''
            --
            -- Names containing space in connection string is automatically enabled.
            -- [] and ' are not recoginized by opendatasource
            -- Note ';' in names in connection string will mess things up.
            --
            select @connect_string = 'SERVER=' + @publisher + ';UID=' + 
                    @login + ';PWD=' + @password + ';'
        end
    end
    --
    -- all done
    --
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSget_publisher_rpc] TO [public] AS [dbo]
GO
