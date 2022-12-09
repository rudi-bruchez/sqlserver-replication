SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSremoveoffloadparameter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSremoveoffloadparameter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSremoveoffloadparameter]
	@job_id [varbinary](16),
	@agenttype [nvarchar](20)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
    
    /*
    ** Declarations
    */
    
    DECLARE @paramstart    INT
    DECLARE @paramend      INT
    DECLARE @paramlen      INT
    DECLARE @paramend2     INT
    DECLARE @command       NVARCHAR(3200) 
    DECLARE @commandtail   NVARCHAR(3200)
    DECLARE @pattern       NVARCHAR(100)

    SELECT @pattern = N'%-[Oo][Ff][Ff][Ll][Oo][Aa][Dd]%'
    SELECT @paramlen = LEN(N'-offload')
    SELECT @command = NULL

    /*
    ** Security Check: require sysadmin
    */
    IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END

    -- use the job_id and the agent type to retrieve the agent command
    -- line, only one agent command step is allowed in a job

    SELECT @command = command FROM msdb.dbo.sysjobsteps 
     WHERE job_id = @job_id AND LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = LOWER(@agenttype collate SQL_Latin1_General_CP1_CS_AS)

    -- purge all instances of '-offload servername' from the agent command line
    SELECT @paramstart = PATINDEX(@pattern, @command)
    WHILE ((@command IS NOT NULL) AND (@paramstart <> 0))
    BEGIN       
        -- extract the part of the command line after the -Offload parameter
        SELECT @commandtail = SUBSTRING(@command, @paramstart + @paramlen, 
                                        LEN(@command) - 
                                        (@paramstart + @paramlen) + 1)

        -- search for the beginning of the server name that follows -offload
        -- in the command tail; note that the empty spaces in the square
        -- bracket of the pattern are actually a space and a tab

        SELECT @paramend = PATINDEX(N'%[^     ]%', @commandtail)

        -- search for the end of the server name that follows -offload
        IF (@paramend <> 0) 
        BEGIN
            SELECT @commandtail = SUBSTRING(@commandtail, @paramend, 
                                            LEN(@commandtail) - @paramend + 1)
            SELECT @paramend2 = PATINDEX(N'%[     ]%', @commandtail) 
            IF (@paramend2 <> 0)
            BEGIN
                SELECT @paramend = @paramend + @paramend2 - 1
            END
            ELSE
            BEGIN
                -- reaching the end of the command line
                SELECT @paramend = @paramend + LEN(@commandtail) - 1
                IF @paramstart > 1 
                BEGIN
                    SELECT @paramstart = @paramstart - 1
                    SELECT @paramend = @paramend + 1
                END
            END
        
        END                
        -- Remove the -Offload parameter from the command line
        SELECT @command = STUFF(@command, @paramstart, @paramlen + @paramend, N'')

        SELECT @paramstart = PATINDEX(@pattern, @command)
    END
    
    -- update the agent command line with all the -offload's removed
    UPDATE msdb.dbo.sysjobsteps 
       SET command = @command
     WHERE job_id = @job_id AND LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = LOWER(@agenttype collate SQL_Latin1_General_CP1_CS_AS)   
    
    RETURN 0
GO
GRANT EXECUTE ON [sys].[sp_MSremoveoffloadparameter] TO [public] AS [dbo]
GO
