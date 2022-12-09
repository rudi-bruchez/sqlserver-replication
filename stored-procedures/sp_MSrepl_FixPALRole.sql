SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_FixPALRole]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_FixPALRole] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_FixPALRole]
	@pubid [uniqueidentifier],
	@role [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @quotedrole sysname
    declare @pubidstr nvarchar(36)
    declare @publication sysname
    declare @publisher_db sysname
    			,@publishingservername sysname

    -- security check
    exec @retcode = sys.sp_MSreplcheck_publish
    if (@retcode <> 0 or @@error <> 0)
        return 1

    exec sys.sp_MSguidtostr @pubid, @pubidstr output
    set @role = 'MSmerge_' + @pubidstr

    exec @retcode = sys.sp_MSgetFixPALRoleAppLock
    if (@retcode <>0 or @@error <>0)
        return 1
    
    -- Add a database role which represents the users who have access to this publication
    -- do this fix up only if the role does not already exist. Assuming that if the role
    -- exists all is well and nothing needs to be done.    
    if exists (select * from sys.database_principals where name=@role and type = 'R')
    begin
        -- check for the db wide pal role first
        if not exists (select * from sys.database_principals where name='MSmerge_PAL_role' and type = 'R')
        begin
                create role MSmerge_PAL_role
                if @@error <> 0 
                    goto FAILURE1
        end
    
        -- check if this role is there in the db wide pal role. 
        if not exists (select 1 from sys.database_role_members r
                            inner join sys.database_principals ur on r.role_principal_id = ur.principal_id
                            inner join sys.database_principals uu on r.member_principal_id = uu.principal_id
                        where ur.name = 'MSmerge_PAL_role'
                        and uu.name = @role)
        begin
            exec @retcode = dbo.sp_addrolemember 'MSmerge_PAL_role', @role
            if (@retcode <> 0 or @@error <> 0)
                goto FAILURE1
        end
        
        if object_id('MSmerge_upgrade_in_progress', 'U') is NULL
            goto SUCCESS
    end

    -- check for the db wide pal role first
    if not exists (select * from sys.database_principals where name='MSmerge_PAL_role' and type = 'R')
    begin
        create role MSmerge_PAL_role
        if @@error <> 0
            goto FAILURE1
    end
        
    -- verify that there is a publication in the current db with this pubid
    select @publisher_db = db_name()
    select @publication = name from dbo.sysmergepublications where pubid = @pubid
    if (@publication is NULL)
    begin    
         RAISERROR (21073, 16, -1)
         goto FAILURE1
    end
    
    if not exists (select * from sys.database_principals where name=@role and type = 'R')
    begin
        DECLARE @createrole nvarchar(200)
        select @createrole = 'create role ' + @role
        exec @retcode = sys.sp_executesql @createrole
        if (@retcode <> 0 or @@error <> 0)
	    goto FAILURE1          
    end

    -- add the publication pal role to the database wide pal role
    exec @retcode = dbo.sp_addrolemember 'MSmerge_PAL_role', @role
    if (@retcode <> 0 or @@error <> 0)
        goto FAILURE
    
    exec @retcode = sys.sp_MSrepl_GrantSelectOnMergeSystemTables @pubid, @role
    if (@retcode <> 0 or @@error <> 0)
        goto FAILURE1

    -- check if there are any users already been granted access to on the
    -- distributor for this publication
    declare @rpcsrvname sysname
    declare @distribdb sysname
    declare @distproc nvarchar(300)
    declare @login sysname
    declare @user sysname
    
    exec @retcode = dbo.sp_MSrepl_getdistributorinfo @rpcsrvname = @rpcsrvname OUTPUT, @distribdb = @distribdb OUTPUT
    IF ((@retcode <> 0) or (@@error <> 0) OR (@distribdb IS NULL) OR (@rpcsrvname IS NULL))
    BEGIN
        RAISERROR (14071, 16, -1)
        goto FAILURE1
    END

    -- using a temp table because of the following error
    -- EXECUTE cannot be used as a source when inserting into a table variable.
    create table #logins_table (login sysname)
    
    SELECT @distproc = QUOTENAME(RTRIM(@rpcsrvname)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.dbo.sp_MSenumerate_PAL'
				,@publishingservername = publishingservername()
    insert into #logins_table exec @distproc 
            @publisher = @publishingservername, 
            @publisher_db = @publisher_db, 
            @publication = @publication
    if @@error <> 0
        goto FAILURE1
        
    declare logins_cursor cursor LOCAL FAST_FORWARD
    for select login from #logins_table
    open logins_cursor
    fetch logins_cursor into @login
    while (@@fetch_status <> -1)
    begin
        select @user = NULL
        select @user = name from sys.database_principals u where u.sid = suser_sid(@login, 0) and u.name <> 'dbo' and
        	exists (select * from sys.database_permissions p where
        		p.class = 0 and p.major_id = 0 and p.minor_id = 0 and p.grantee_principal_id = u.principal_id and
        		p.type = 'CO' and p.state in ('G','W')) and
        	not exists (select * from sys.database_permissions p where
        		p.class = 0 and p.major_id = 0 and p.minor_id = 0 and p.grantee_principal_id = u.principal_id and
        		p.type = 'CO' and p.state = 'D') -- connect permission not denied
        if @user is not NULL
        begin
            exec @retcode = dbo.sp_addrolemember @role, @user
            if (@retcode <> 0 or @@error <> 0)
                goto FAILURE

            exec @retcode = sys.sp_MSgrantconnectreplication @user
            if (@retcode <> 0 or @@error <> 0)
                return 1
            
        end
        fetch logins_cursor into @login
    end
    close logins_cursor
    deallocate logins_cursor

    drop table #logins_table
 SUCCESS:
    exec sys.sp_MSreleaseFixPALRoleAppLock
    return 0
    
FAILURE:
    close logins_cursor
    deallocate logins_cursor
    drop table #logins_table

FAILURE1:
    exec sys.sp_MSreleaseFixPALRoleAppLock
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_FixPALRole] TO [public] AS [dbo]
GO
