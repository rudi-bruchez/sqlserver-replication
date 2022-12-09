SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_redirect_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_redirect_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_redirect_publisher]
	@original_publisher [sysname],
	@publisher_db [sysname],
	@redirected_publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
   
	declare @dbname sysname = db_name()
 
	-- Security check
	--
	if is_member(N'db_owner') <> 1
	begin
		raiserror (21873, 16, -1, 'sys.sp_redirect_publisher')
		return 1
	end
	
	-- Has to be executed from a distribution database
	--
	if (sys.fn_MSrepl_isdistdb (@dbname) <> 1)
	begin
		raiserror(21874, 16, -1, 'sys.sp_redirect_publisher', @dbname)
		return 1
	end
 
	-- Input parameters must both be non-null
	--
	if @original_publisher is null or
		@publisher_db is null
	begin
		raiserror (21875, 16, -1, 'sys.sp_redirect_publisher')
		return 1
	end
	
	if exists 
		(	select redirected_publisher from MSredirected_publishers
			where publisher_db = rtrim(@publisher_db)
			and   upper(original_publisher) = upper(rtrim(@original_publisher)))
	begin
		if @redirected_publisher is not null
		begin
			update MSredirected_publishers 
			set redirected_publisher = rtrim(@redirected_publisher)
			where publisher_db = rtrim(@publisher_db)
			and   upper(original_publisher) = upper(rtrim(@original_publisher))
		end
		else
		begin
			delete from MSredirected_publishers 
			where publisher_db = rtrim(@publisher_db)
			and   upper(original_publisher) = upper(rtrim(@original_publisher))			
		end
	end
	else	
	begin
		insert into MSredirected_publishers
		values (rtrim(@original_publisher), rtrim(@publisher_db), rtrim(@redirected_publisher))
	end	 
		
	return 0		  				
end
GO
GRANT EXECUTE ON [sys].[sp_redirect_publisher] TO [public] AS [dbo]
GO
