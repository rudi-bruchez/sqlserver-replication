SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_cdc_start_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_cdc_start_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_cdc_start_job]
	@job_type [nvarchar](20)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @job_id uniqueidentifier
           ,@retcode int
           ,@db_name sysname
  
    set @db_name = db_name()
           
	-- Verify CDC is supported for this SQL Server edition
    IF ([sys].[fn_cdc_is_supported]() = 1)
    begin
        declare @edition sysname
        select @edition = CONVERT(sysname, SERVERPROPERTY('Edition'))
        raiserror(22988, 16, -1, @edition)
        return (1)
    end

    --
    -- Job security check proc
    --
    exec @retcode = [sys].[sp_MScdc_job_security_check]
    if @retcode <> 0 or @@error <> 0
        return(1)
        
    -- Verify database is currently enabled for change data capture
    if ([sys].[fn_cdc_is_db_enabled]() != 1)
    begin
		raiserror(22901, 16, -1, @db_name)
        return 1
    end
        
	set @job_type = rtrim(ltrim(lower(@job_type)))
	        
    -- Verify parameter
    if ((@job_type is null) or (@job_type not in (N'capture', N'cleanup')))
    begin
        raiserror(22992, 16, -1, @job_type)
        return(1)
    end
    
    --
    -- Insure that transactional replication is not also enabled for the database
    --
    if (@job_type = N'capture')
    begin
		exec @retcode = [sys].[sp_MScdc_tranrepl_check] 
		if @retcode <> 0 or @@error <> 0
			return (1)
	end
	
	-- Call internal procedure to start the job
	exec @retcode = sys.sp_cdc_start_job_internal
		@job_type
		
	if @@error <> 0 or @retcode <> 0
		return 1
		
	return 0		
end

--
-- Name: [sys].[sp_cdc_stop_job_internal]
--
-- Description:
--	Stops the CDC job if it exists
--
-- Parameters: 
--   @job_type	'capture' (default), 'cleanup'
--
-- Returns: 0 - success
--          1 - Otherwise
--
-- Security: Internal.
--
--	        Module requires with execute as 'dbo' in order to authorize
--          access to msdb.
-- 
raiserror(15339,-1,-1,'[sys].[sp_cdc_stop_job_internal]')
GO
GRANT EXECUTE ON [sys].[sp_cdc_start_job] TO [public] AS [dbo]
GO
