SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_cdc_add_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_cdc_add_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_cdc_add_job]
	@job_type [nvarchar](20),
	@start_job [bit],
	@maxtrans [int],
	@maxscans [int],
	@continuous [bit],
	@pollinginterval [bigint],
	@retention [bigint],
	@threshold [bigint],
	@check_for_logreader [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @job_name sysname
           ,@retval   int
           ,@job_id   uniqueidentifier
           ,@old_job_id   uniqueidentifier
           ,@job_step_uid  uniqueidentifier
           ,@index    int
           ,@category_name sysname
           ,@command  nvarchar(1000)
           ,@server   sysname
           ,@databasename sysname
           ,@user     sysname
           ,@schedule_name sysname
           ,@database_id int
           ,@valid_job bit
           ,@description nvarchar(100)
           ,@step_name nvarchar(100)
			,@logreader_exists bit

	-- Verify CDC is supported for this SQL Server edition
    IF ([sys].[fn_cdc_is_supported]() = 1)
    BEGIN
        DECLARE @edition sysname
        SELECT @edition = CONVERT(sysname, SERVERPROPERTY('Edition'))
        RAISERROR(22988, 16, -1, @edition)
        RETURN (1)
    END
    
	--
    -- CDC Job security check 
    --
    exec @retval = [sys].[sp_MScdc_job_security_check] 
    if @retval <> 0 or @@error <> 0
        return (1)
        
    -- Verify database is currently enabled for change data capture
    if ([sys].[fn_cdc_is_db_enabled]() != 1)
    begin
		set @databasename = db_name()
		raiserror(22901, 16, -1, @databasename)
        return 1
    end
            
	set @job_type = rtrim(ltrim(lower(@job_type)))

	--
    -- Parameter validation
    --
    
    -- job type must be either 1 or 2
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
		set @logreader_exists = 0
		exec @retval = [sys].[sp_MScdc_tranrepl_check] @logreader_exists = @logreader_exists output, @skip_remote_check = @check_for_logreader
		if @retval <> 0 or @@error <> 0
			return (1)
	end
	--coming from sp_cdc_enable_table, when db is published for tran and there is logreader agent already, don't raiserror
	if (@logreader_exists = 1) and (@check_for_logreader = 1)
		return 0
	
	-- Set job specific defaults
	if (@job_type = N'capture')
	begin
		if (@continuous is null)
		begin
			if (serverproperty('EngineEdition') <> 5)
			begin
			set @continuous = 1
			end
			else
			begin
				set @continuous = 0
			end
		end
			
		if (@maxtrans is null)
			set @maxtrans = 500
			
		if (@maxscans is null)
			set @maxscans = 10
			
		if (@pollinginterval is null)
		begin
			if (@continuous = 1)
				set @pollinginterval = 5
			else
				set @pollinginterval = 0	
		end		
	end
	else 
	begin
		if (@retention is null)
			set @retention = 4320
		if (@threshold is null)
			set @threshold = 5000	
	end

	-- Only @retention, @threshold, and @start_job may have non-null values for cleanup job
    if (@job_type = N'cleanup') and 
		( (@pollinginterval is not null) or
		  (@maxtrans is not null) or
		  (@continuous is not null) or
		  (@maxscans is not null))
	begin
		raiserror(22996, 16, -1)
		return(1)
	end	
	
	-- Only @pollinginterval, @maxtrans, @maxscans, @continuous, and @start_job may have non-null values for capture job
    if (@job_type = N'capture') and ((@retention is not null) or (@threshold is not null)) 
	begin
		raiserror(22995, 16, -1)
		return(1)
	end
	
	if (@job_type = N'capture')
		select @retention = 0, @threshold = 0
	else
		select @pollinginterval = 0, @maxtrans = 0, @continuous = 0, @maxscans = 0
	
    -- 24 hour maximum on polling interval
    if (@pollinginterval > (60*60*24)) or (@pollinginterval < 0)
	begin
		raiserror(22990, 16, -1)
		return(1)
	end		

    -- Retention may not be negative or greater than 52594800 if adding cleanup job
    if (@job_type = N'cleanup') and ((@retention <= 0) or (@retention > 52594800))
	begin
		raiserror(22994, 16, -1)
		return(1)
	end
	
    -- Threshold may not be negative if adding cleanup job
    if (@job_type = N'cleanup') and (@threshold <= 0) 
	begin
		raiserror(22850, 16, -1)
		return(1)
	end
	
	-- maxtrans must be greater than 0
	if (@job_type = N'capture') and (@maxtrans <= 0)
	begin
		raiserror(22991, 16, -1)
		return(1)
	end
	
	-- maxscans must be greater than 0
	if (@job_type = N'capture') and (@maxscans <= 0)
	begin
		raiserror(22970, 16, -1)
		return(1)
	end
	
	if (serverproperty('EngineEdition') <> 5)
	begin
	-- Call internal stored procedure to create the job
	exec @retval = sys.sp_cdc_add_job_internal
	    @job_type,
		@start_job,
		@maxtrans,
		@maxscans,
		@continuous,
		@pollinginterval,
		@retention,
		@threshold
	end
	else 
	begin
		-- Call internal stored procedure to create the job
		exec @retval = sys.sp_cdc_add_job_internal_db_scoped
			@job_type,
			@start_job,
			@maxtrans,
			@maxscans,
			@continuous,
			@pollinginterval,
			@retention,
			@threshold
	end
	
    if @retval <> 0 or @@error <> 0
        return (1)

	return 0	
end
GO
GRANT EXECUTE ON [sys].[sp_cdc_add_job] TO [public] AS [dbo]
GO
