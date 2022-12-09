SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplcheck_pull]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplcheck_pull] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplcheck_pull]
	@publication [sysname],
	@raise_fatal_error [bit],
	@pubid [uniqueidentifier],
	@given_login [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @login sysname
                ,@dbname sysname
                ,@retcode int
                ,@err_level int
                ,@tranpubid int
                ,@publisher_type sysname
                
    --
    -- Special processing if explicit login was not provided
    --
    if @given_login is null 
    begin
        --
        -- explict login not provided
        -- sysadmin or db_owner have access
        --
        if (is_srvrolemember('sysadmin') = 1 or is_member('db_owner') = 1)
            return (0)
    end
    --
    -- Get the current login
    -- NOTE: why is user_name() not being used
    --
    select @login = suser_sname(suser_sid())
    --
    -- Special processing if explicit login was provided
    --
    if (@given_login is not null) 
    begin
        --
        -- More special processing
        --
        if (@login = @given_login)
        begin
            --
            -- given login is same as current login
            -- sysadmin or db_owner have access
            --
            if (is_srvrolemember('sysadmin') = 1 or is_member('db_owner') = 1)
                return (0)
        end
        else
        begin
            --
            -- To determine whether another login has access to a publication
            -- requires current user to be db_owner in the publishing database
            --
            if is_member('db_owner') <> 1
            begin
                raiserror (21050, 16, -1)
                return (1)
            end
            --
            -- given login is not same as current login
            -- if given login is sysadmin or db_owner member then it has access
            --
            if (is_srvrolemember('sysadmin', @given_login) = 1 or sys.fn_isrolemember(1, @given_login, NULL) = 1)
                return (0)
            select @login = @given_login
        end
    end
    --
    -- initialize
    --
    if (@publisher is null)
        select @publisher = publishingservername()
    if (@publication is not null)
    begin
        select @pubid = NULL
        if object_id('dbo.syspublications') is not null
        begin
            --
            -- get the publisher type
            --
            EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher      = @publisher,
                                                    			@publisher_type = @publisher_type OUTPUT
            IF @@error <> 0
            BEGIN
                 RAISERROR (14071, 16, -1)
                 return (1)
            END
            --
            -- get the pubid
            --
            SELECT @tranpubid = sys.fn_MSrepl_getpubid(@publication, @publisher, @publisher_type)
        end
        if object_id('dbo.sysmergepublications') is not null
            select @pubid = pubid from sysmergepublications where name = @publication and upper(publisher) = upper(@publisher)
        if (@tranpubid is null and @pubid is null)
        begin
            raiserror(20026, 16, -1, @publication)
            return 1
        end
    end
    else if (@pubid is not null)
    begin
        select @publication = NULL
        if object_id('dbo.sysmergepublications') is not null
            select @publication = name from sysmergepublications where pubid = @pubid and upper(publisher) = upper(@publisher)
        if (@publication is null)
        begin
            raiserror(21723, 16, -1, 'sp_MSreplcheck_pull')
            return 1
        end
    end
    --
    -- check the PAL roles
    --
    if (@tranpubid is null and @pubid is null)
    begin
        declare @lrpc nvarchar(400)
                    ,@hasaccess int
        --
        -- generic check
        -- user must be member of any existing PAL roles
        -- check the current database first
        --
        if (sys.fn_isrolemember(0, @login, NULL) = 1)
        begin
            --
            -- has access
            --
            return 0
        end
        else
        begin
            --
            -- check the other publishing dbs
            --
            declare #hcpubdb cursor local fast_forward for
            select  name
            from master.dbo.sysdatabases 
            where has_dbaccess(name) = 1
                and ((category & 1 != 0)  or (category & 4 != 0))
                and name != db_name()
                and name not in
                        (
                        N'master' COLLATE DATABASE_DEFAULT,
                        N'tempdb' COLLATE DATABASE_DEFAULT,
                        N'msdb'   COLLATE DATABASE_DEFAULT,
                        N'model'   COLLATE DATABASE_DEFAULT
                        )
                and sys.fn_MSrepl_isdistdb (name) = 0
            for read only

            open #hcpubdb
            fetch #hcpubdb into @dbname
            while (@@fetch_status <> -1)
            begin
                --
                -- Check if the user is PAL member in this db
                --
                select @hasaccess = 0
                        ,@lrpc = quotename(@dbname) + '.sys.sp_MScheck_palroleinpubdb'
                exec @retcode = @lrpc @login, @hasaccess output
                if (@retcode != 0 or @@error != 0)
                begin
                    return 1
                end
                if (@hasaccess = 1)
                begin
                    --
                    -- has access
                    --
                    return 0
                end
                --
                -- get next publishing db
                --
                fetch #hcpubdb into @dbname
            end
            close #hcpubdb
            deallocate #hcpubdb
            --
            -- if we have reached here 
            -- it mean the user has is not PAL member of any publication in this server
            --
            goto error
        end
    end
    else if (@pubid is not null)
    begin
        if @given_login is not NULL
        begin
            -- check if the given login is a member of the specific merge publication's pal role
            declare @role sysname
            declare @pubidstr nvarchar(40)
            
            exec sys.sp_MSguidtostr @pubid, @pubidstr output
            set @role = 'MSmerge_' + @pubidstr
            
            if exists (select * from sys.database_role_members
                where role_principal_id in (select principal_id 
                                                 from sys.database_principals 
                                                 where name = @role)
                    and member_principal_id = (select dp.principal_id
                                                    from sys.database_principals as dp join master.dbo.syslogins as s
                                                    on dp.sid = s.sid
                                                    and s.name = @given_login))
                -- has access
                return 0
        end
        else if (1 = {fn ISPALUSER(@pubid)})
        begin
            --
            -- has access
            --
            return 0
        end
    end
    else
    begin
        --
        -- check for specific transactional publication
        -- the user must be member of specific PAL role
        --
        if (sys.fn_isrolemember(2, @login, @tranpubid) = 1)
        begin
            --
            -- has access
            --
            return 0
        end
    end
    --
    -- if we reach here, we don't have access. Return error
    --
error:
    select @err_level = case when (@raise_fatal_error = 1) then 14 else 10 end
    IF @publication IS NOT NULL
        RAISERROR (21049, @err_level, -1, @login, @publication)
    ELSE
        RAISERROR (21688, @err_level, -1, @login, @publisher)
    return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplcheck_pull] TO [public] AS [dbo]
GO
