SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdistpublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdistpublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdistpublisher]
	@publisher [sysname],
	@check_user [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

    declare @username sysname
                ,@command nvarchar(4000)
                ,@fallowaccess bit
                ,@db_name sysname
                ,@cmdproc nvarchar(1000)
                ,@has_pm bit
                ,@distbit int
                ,@retcode int
                ,@publisher_name sysname
                ,@distdb sysname
                ,@cmd nvarchar(4000)
                ,@distdbforlistener sysname
                ,@orig_publisher sysname

    -- this will be used for user check
    declare @distdbs table (publisher sysname, name sysname, primary key(publisher,name))
    declare @MSdistlogins table (
        name sysname
        ,distribution_db sysname
        ,login sysname
        ,password nvarchar(524)
        ,storage_connection_string nvarchar(779)
        ,primary key(name, distribution_db, login))
        set @orig_publisher = NULL
    declare @AccountKey sysname = N';AccountKey='
    declare @AccountKeyLen int = LEN(@AccountKey)

	--
	-- create temp table for collection of distribution dbs
	-- this will be used for user check
	--
	/*
	if object_id('tempdb..#distdbs') is not NULL
	begin
		drop table #distdbs
	end
	
	create table #distdbs (publisher sysname collate database_default, name sysname collate database_default)

	if object_id('tempdb..#MSdistlogins') is not NULL
	begin
		drop table #MSdistlogins
	end

	create table #MSdistlogins (name sysname, distribution_db sysname, login sysname, password nvarchar(524))
	*/
 
	--
	-- @publisher : validate
	--
	IF @publisher IS null
	begin
		raiserror (14043, 16, -1, '@publisher', 'sp_helpdistpublisher')
		return (1)
	end
	--
	-- Check to make sure this is a distributor
	--
	IF NOT EXISTS (select * from master.sys.servers
			  where UPPER(data_source collate database_default) = UPPER(@@SERVERNAME)
				 AND is_distributor = 1)
	begin
		if @publisher <> N'%' 
		begin
				raiserror (14114, 16, -1, @@SERVERNAME)
				return(1)
		end
		else
			return(0)
	end

	if @publisher <> N'%'
	begin
		-- Get publisher without port number
		exec sys.sp_MSget_server_portinfo 
			@name = @publisher, 
			@srvname = @publisher OUTPUT
	end

    IF @publisher <> N'%' AND NOT EXISTS (select * from msdb.dbo.MSdistpublishers
            where name collate database_default = UPPER(@publisher))
    begin
        -- If we are here then either we have incorrect @publisher or it could be an AG listener for publisher
        -- To find if its an AG listener for publisher, we need to find the distribution db that has this listener. Note - we can have more than 1 distribution DB
        declare #hcdistdb cursor local fast_forward for
        select name from msdb.dbo.MSdistributiondbs
        open #hcdistdb
        fetch next from #hcdistdb into @distdb
        while (@@fetch_status != -1)
        begin
            --
            -- get original publisher from the current distribution db
            --
            select @cmd = quotename(@distdb) + '.sys.sp_replmonitorgetoriginalpublisher'
            exec @cmd @publisher, @orig_publisher OUTPUT
            if @@error != 0
                goto UNDO
            if @orig_publisher is NOT NULL -- we found the match
            begin 
                set @distdbforlistener = @distdb
                break
            end 
            --
            -- get next distribution db
            --
            fetch next from #hcdistdb into @distdb
        end -- while (@@fetch_status != -1)
        close #hcdistdb
        deallocate #hcdistdb

        -- if @orig_publisher is not null, then it is the original publisher for AG listener
        if @orig_publisher is NOT NULL 
        BEGIN
            set @publisher = @orig_publisher  -- We found the match and from now on we should use @orig_publisher as publisher
        END
        else 
        BEGIN
            raiserror (14080, 11, -1, @publisher)  -- user supplied incorrect value for @publisher
			return (1)
        END
    end
    --
    -- allow access to login information if running as sysadmin
    -- If sysadmin, no need for filtering - override the input for user check
    --
    if (is_srvrolemember(N'sysadmin') = 1)
        select @fallowaccess = 1 ,@check_user = 0
    else
        select @fallowaccess = 0, @check_user = 1 -- Force nonsysadmin user to be always checked
    --
    -- Processing for non sysadmin user
    --
    if (@fallowaccess = 0 and @check_user = 1)
    begin
        --
        -- Has publisher been specified
        --
        if (@publisher <> N'%')
        begin
            --
            -- doing specific publisher query.
            -- force a dbowner check in the specific distribution db        
            --
            select @db_name = distribution_db
            from msdb.dbo.MSdistpublishers
            where name collate database_default = UPPER(@publisher)

			select @cmdproc = quotename(@db_name) + N'.sys.sp_executesql'
							, @has_pm = 0
			exec @cmdproc N'if is_member(N''db_owner'') = 1 set @has_pm = 1', 
							N'@has_pm bit output',
							@has_pm output
			if @@ERROR <> 0
				return(1)
			--
			-- if we are the DBO of the specific distribution db AND we are issuing the
			-- query from a replication agent - then allow access to login info for specific
			-- publisher case - Queue reader agent does this
			--
			if (@has_pm = 1 and sessionproperty(N'replication_agent') = 1)
				select @fallowaccess = 1

			-- if no access yet, see if the user is 'repl_monitor',
			-- or in the PAL for any publications associated with this publisher
			if @has_pm = 0
			begin
				select @cmdproc = quotename(@db_name) + N'.sys.sp_MSrepl_DistDBPALAccess'
				exec @retcode = @cmdproc
					@publisher = @publisher

				if @@ERROR <> 0
					return(1)

				if @retcode = 0
				BEGIN
					select @has_pm = 1
				END
				ELSE
				BEGIN
					-- Security: avoid info disclosure for users that don't have access.
					-- Return publisher doesn't exist instead of empty set
					raiserror (14080, 11, -1, @publisher)
					return (1)
				END
			end
			--
			-- If use has permissions then store this db_name
			--
			if ((@has_pm = 1) or (sessionproperty(N'replication_agent') = 1))
				insert into @distdbs (publisher, name) values (upper(@publisher), @db_name)
		end
		else 
		begin
			--
			-- publisher not specified and user check enabled
			-- perform db owner check for distribution dbs
			--
			declare #hCdatabase CURSOR LOCAL FAST_FORWARD FOR
				select msdp.name,
						msdp.distribution_db
				from msdb.dbo.MSdistpublishers msdp
					join master.sys.databases sysdb
						on msdp.distribution_db collate database_default = sysdb.name collate database_default
							and sysdb.is_distributor = 1 
							and has_dbaccess(sysdb.name) = 1
			for read only

			open #hCdatabase
			fetch next from #hCdatabase into @publisher_name, @db_name
			while (@@fetch_status <> -1)
			begin
				-- Allow access if the user is 'db_owner', 'replmonitor' or in the PAL for any
				-- publications associated with any publisher using this distribution database
				begin
					select @cmdproc = quotename(@db_name) + N'.sys.sp_MSrepl_DistDBPALAccess'
					exec @retcode = @cmdproc @publisher = @publisher_name
					if @@ERROR <> 0
						return(1)

					if @retcode = 0
						insert into @distdbs (publisher, name) values (upper(@publisher_name), @db_name)
				end
				-- fetch next entry
				fetch next from #hCdatabase into @publisher_name, @db_name
			end
			close #hCdatabase
			deallocate #hCdatabase
		end -- publisher not specified
	end -- if (@fallowaccess = 0 and @check_user = 1) block

	-- load the logins table
	insert into @MSdistlogins (name, distribution_db, login, password, storage_connection_string)
		SELECT name, distribution_db, login, sys.fn_repldecryptver4(password),
			   LEFT(storage_connection_string,
					CHARINDEX(@AccountKey, storage_connection_string COLLATE Latin1_General_CI_AI) + @AccountKeyLen - 1
			   ) -- storage connection string leading part, including 'AccountKey='
			   + sys.fn_repldecryptver4(
					SUBSTRING(storage_connection_string,
							  CHARINDEX(@AccountKey, storage_connection_string COLLATE Latin1_General_CI_AI) + @AccountKeyLen,
							  LEN(storage_connection_string))
			   ) -- decrypted key, in case of v4 encryption algorithm being used
		FROM msdb.dbo.MSdistpublishers

	/*
	declare #curDistDB CURSOR LOCAL FAST_FORWARD FOR
		select name,
				distribution_db
		from msdb.dbo.MSdistpublishers

	open #curDistDB

	fetch next from #curDistDB into @publisher_name, @db_name
	while (@@fetch_status <> -1)
	begin
		select @command = QUOTENAME(@db_name) + N'.sys.sp_MShelpdistpublisher'

        insert into @MSdistlogins
            exec @command @publisher = @publisher_name, @db_name
        if @@ERROR <> 0 return(1)
        -- fetch next entry
        fetch next from #curDistDB into @publisher_name, @db_name
    end
    close #curDistDB
    deallocate #curDistDB
    */
    
    --
    -- Generate result query
    --
    SELECT  p.name,
                p.distribution_db,
                p.security_mode, 
                -- Not to return login unless allowed access.
                N'login'    = CASE
                                WHEN (@fallowaccess = 1) THEN p.login
                                ELSE cast(NULL as sysname)
                                END,
                -- Not to return password unless allowed access.
                N'password' = CASE
                                    WHEN (@fallowaccess = 1) THEN msdl.password
                                    ELSE cast(NULL as sysname)
                                    END,
                p.active,
                p.working_directory,
                p.trusted,
                p.thirdparty_flag,
                p.publisher_type,
                N'publisher_data_source' = s.data_source,
                N'storage_connection_string' = CASE
                                    WHEN (@fallowaccess = 1 AND cast(sessionproperty('replication_agent') as int) = 1 AND sys.fn_MSrepl_editionid() = 32)
                                    THEN msdl.storage_connection_string
                                    ELSE cast(NULL as sysname)
                                    END
    FROM msdb.dbo.MSdistpublishers as p 
        join master.sys.servers as s 
            on p.name collate database_default = s.name collate database_default
        join @MSdistlogins as msdl
            on msdl.name = p.name collate database_default
                AND msdl.distribution_db = p.distribution_db collate database_default
                AND msdl.login = p.login collate database_default
    WHERE ((@publisher = N'%') OR (p.name  collate database_default= UPPER(@publisher)))
        AND (@check_user = 0 
                    OR EXISTS (SELECT * 
                                    FROM @distdbs as d 
                                    WHERE d.name = p.distribution_db collate database_default
                                        AND d.publisher = p.name collate database_default))
    --
    -- all done
    --
    return 0
UNDO:
    close #hcdistdb
    deallocate #hcdistdb
    return 1

end
GO
GRANT EXECUTE ON [sys].[sp_helpdistpublisher] TO [public] AS [dbo]
GO
