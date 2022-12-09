SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_get_redirected_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_get_redirected_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_get_redirected_publisher]
	@original_publisher [sysname],
	@publisher_db [sysname],
	@bypass_publisher_validation [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
   
	declare @redirected_publisher sysname,
		@error_severity int,
		@error_number int,
		@error_message nvarchar(4000),
		@dbname sysname,
		@retcode int
   
	select @redirected_publisher = null,
		@error_severity = 0,
		@error_number = 0,
		@error_message = null,
		@dbname = db_name(),
		@retcode = 0
   
	begin try
 
		-- Has to be executed from distribution database
		--
		if (sys.fn_MSrepl_isdistdb (@dbname) <> 1)
		begin
			raiserror(21874, 16, -1, 'sys.sp_get_redirected_publisher', @dbname)
		end	
			
		-- Verify input parameters are not null
		--
		if @original_publisher is null or
		@publisher_db is null
		begin
			raiserror (21875, 16, -1, 'sys.sp_get_redirected_publisher')
		end
		
		-- Security check
		--
		if is_member(N'db_owner') <> 1
		begin
			exec @retcode = sys.sp_MSrepl_DistDBPALAccess @original_publisher
		
			if (@@error <> 0) or(@retcode <> 0)
			begin
				raiserror (21873, 16, -1, 'sys.sp_get_redirected_publisher')
			end
		end    
		
		-- If the publisher of the database has not been redirected,
		-- or the @bypass_publisher_validation parameter was set to 1
		-- return without performing any validation.
		--
		select @redirected_publisher = redirected_publisher
		from MSredirected_publishers
		where upper(original_publisher) = upper(rtrim(@original_publisher))
		and publisher_db = rtrim(@publisher_db)
		
		if @redirected_publisher is not null and
			@bypass_publisher_validation = 0
		begin
			-- Call the validation stored procedure to verify
			-- that the target of redirection is a suitable
			-- publisher for the database
			--
			exec sys.sp_validate_redirected_publisher
				@original_publisher,
				@publisher_db,
				@redirected_publisher output
		end		
			
	end try
	
	begin catch
	
		-- Set output parameters for raised error
		--
		select @error_severity = ERROR_SEVERITY(),
			@error_number = ERROR_NUMBER(),
			@error_message = ERROR_MESSAGE()
		
	end catch
	
	select @redirected_publisher as redirected_publisher,
		@error_number as error_number,
		@error_severity as error_severity,
		@error_message as error_message		
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_get_redirected_publisher] TO [public] AS [dbo]
GO
