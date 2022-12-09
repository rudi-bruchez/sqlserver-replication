SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_change_repl_serverport]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_change_repl_serverport] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_change_repl_serverport]
	@server [sysname],
	@port [int]
WITH EXECUTE AS CALLER
AS
BEGIN
    -- Security Check: require sysadmin
    IF IS_SRVROLEMEMBER('sysadmin') != 1
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN 1
    END

    -- Must be in master db.
    IF db_name() <> 'master'
    BEGIN
        RAISERROR(5001, 16,-1)
        RETURN 1
    END

    -- Check that port is a valid value
    IF @port IS NOT NULL AND @port NOT BETWEEN 0 AND 65535
    BEGIN
        RAISERROR(14198, 16, -1, '@port', '1..65535')
        RETURN 1
    END

    DECLARE @connectString sysname;
    DECLARE @addrString nvarchar(4000);

    SET @server = UPPER(@server)

    -- The connection string is what we are going to insert into command line.
    -- It is server,port (the second part is only appended if the port is not default)
    -- The addrString is the provider entry into linked servers
    IF @port IS NULL OR @port = 1433
    BEGIN
        SET @connectString = @server
        SET @addrString = ''
    END
    ELSE
    BEGIN
        SET @connectString = @server + ',' + CAST(@port as nvarchar(6))
        SET @addrString = 'addr=tcp:' + @connectString
    END

    -- quote connection string if needed ([server,port])
    SET @connectString = CASE
                         WHEN SUBSTRING(@connectString, 1, 1) LIKE '[a-zA-Z_@#]' AND @connectString LIKE '%[^a-zA-Z0-9_@#$]%'
                         THEN QUOTENAME(@connectString)
                         ELSE @connectString
    END
    
    -- Create CTE where each row is a job id, step id, a parameter from the command line
    -- (without the - or /) and the value of that parameter as the argument.
    ;WITH Parameters(job_id, step_id, par, argument)
    AS (
        SELECT js.job_id
             , js.step_id
             , p.parameters
             -- The case changes the argument of the Publisher, Distributor or Subscriber parameter
             -- to the new connection string if it was pointing at a connection string with the server
             , CASE WHEN p.parameters IN ('Publisher', 'Distributor', 'Subscriber') AND
                         (CASE
                             WHEN CHARINDEX(',', PARSENAME(p.arguments, 1), 0) = 0 THEN PARSENAME(p.arguments, 1)
                             ELSE UPPER(SUBSTRING(PARSENAME(p.arguments, 1), 0, CHARINDEX(',', PARSENAME(p.arguments, 1), 0)))
                          END) = @server
                    THEN @connectString ELSE p.arguments END
        FROM [msdb].[dbo].[sysjobsteps] js
        JOIN [msdb].[dbo].sysjobs sj
            ON sj.job_id = js.job_id
        JOIN [msdb].[dbo].syscategories sc
            ON sj.category_id = sc.category_id AND
               -- We check the category to only select jobs that are replication-related
               sc.name IN ('REPL-Alert Response',
                           'REPL-Checkup',
                           'REPL-Distribution',
                           'REPL-Distribution Cleanup',
                           'REPL-History Cleanup',
                           'Replication',
                           'REPL-LogReader',
                           'REPL-Merge',
                           'REPL-QueueReader', 
                           'REPL-Snapshot', 
                           'REPL-Subscription Cleanup')
        -- The cross apply function breaks the command line into the parameter/argument pairs
        CROSS APPLY sys.fn_getparametervalues(js.command) p
        -- Check only commands that contain the server name
        WHERE UPPER(js.command) LIKE ('%' + @server + '%')
    )
    UPDATE [msdb].[dbo].[sysjobsteps]
    SET [msdb].[dbo].[sysjobsteps].command = STUFF(
        -- Merge parameters from the same job and job step into a single command line with - proceeding the
        -- parameter name
        (SELECT N' ' + N'-' + pInner.par + (CASE WHEN pInner.argument = '' THEN '' ELSE N' ' + pInner.argument END)
                FROM Parameters pInner
                WHERE pInner.job_id = p.job_id AND pInner.step_id = p.step_id
                FOR XML PATH('')
        ), 1, 1, '' )
    FROM Parameters p
    WHERE [msdb].[dbo].[sysjobsteps].job_id = p.job_id AND [msdb].[dbo].[sysjobsteps].step_id = p.step_id

    -- Set the provider string property of linked servers to the new value. Update all linked servers
    -- that have matching data_source property, except the one that has the name matching the server -
    -- the pseudo loopback server used for @@SERVERNAME (server_id = 0)
    DECLARE @cmd NVARCHAR(MAX)=N''
    SELECT @cmd=(SELECT N'EXEC sp_serveroption N''' + s.name + N''', N''provider string'', @addrString;' + CHAR(10)
             FROM sys.servers s
             WHERE server_id <> 0 AND UPPER(data_source) = @server FOR XML PATH(''))

    EXEC sp_executesql @cmd, N'@addrString nvarchar(4000)', @addrString=@addrString

END
GO
GRANT EXECUTE ON [sys].[sp_change_repl_serverport] TO [public] AS [dbo]
GO
