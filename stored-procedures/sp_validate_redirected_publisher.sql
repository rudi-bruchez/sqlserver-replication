SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validate_redirected_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validate_redirected_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validate_redirected_publisher]
	@original_publisher [sysname],
	@publisher_db [sysname],
	@redirected_publisher [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
begin

   set nocount on

   declare 
		@target_server sysname,
		@publisher_linked_server sysname,
		@dbname sysname,
		@retcode int
		
   set @redirected_publisher = null
   set @target_server = null
   set @publisher_linked_server = null
   set @dbname = db_name()
   
	-- Has to be executed from a distribution database
	--
	if (sys.fn_MSrepl_isdistdb (@dbname) <> 1)
	begin
		raiserror(21874, 16, -1, 'sys.sp_validate_redirected_publisher', @dbname)
		return 1
	end	
		
	-- Verify input parameters are not NULL
	--
	if @original_publisher is null or
		@publisher_db is null
	begin
		raiserror (21875, 16, -1, 'sys.sp_validate_redirected_publisher')
		return 1
	end
	
	-- Security check
	--
	if is_member(N'db_owner') <> 1
	begin
		exec @retcode = sys.sp_MSrepl_DistDBPALAccess @original_publisher
		
		if (@retcode <> 0) or (@@error <> 0)
		begin
			raiserror (21873, 16, -1, 'sys.sp_validate_redirected_publisher')
			return 1
		end
	end
		
	-- If the publisher of the database has not been redirected
	-- return without performing any validation.
	--
	select @redirected_publisher = redirected_publisher
	from MSredirected_publishers
	where upper(original_publisher) = upper(rtrim(@original_publisher))
	and publisher_db = rtrim(@publisher_db)
		
	if @redirected_publisher is null
	begin
		return 0
	end
		
    -- Verify that the original publisher is a SQL Server publisher of this 
    -- distributor.
    --
    if not exists (
        select name from msdb.dbo.MSdistpublishers
        where upper(rtrim(@original_publisher)) = upper(name) collate database_default
        and N'MSSQLSERVER' = upper(publisher_type)) 
    begin
        raiserror (21876, 16, -1, @@servername, @original_publisher, @publisher_db)
        return 1 
    end
    
    -- Verify that there is a sysservers entry for the original publisher 
    -- at the distributor.
    --
    if not exists (
	    select srvid
	    from MSreplservers
	    where upper(srvname) collate database_default = upper(rtrim(@original_publisher)))
	begin
		raiserror (21877, 16, -1, @original_publisher, @publisher_db)
		return 1 
	end
				
	-- Create a linked server to connect to the target of redirection.
	--
	exec @retcode = sys.sp_hadr_create_linked_server @original_publisher, @publisher_db,
		@redirected_publisher, @publisher_linked_server output
	if @retcode <> 0
		return 1    

	-- Get the name of the target host
	--    
	exec @retcode = sys.sp_hadr_get_target_server @original_publisher, @publisher_db,
		@redirected_publisher, @publisher_linked_server, @target_server output
	if @retcode <> 0
		return 1    
		
	-- Verify that the redirected publisher is configured for replication
	--
	exec @retcode = sys.sp_hadr_verify_configured_for_repl @target_server, @publisher_db,
		@publisher_linked_server
	if @retcode <> 0
		return 1    
	
	-- Verify that the original publisher and redirected publisher both share the same
	-- distributor 
	--
	exec @retcode = sys.sp_hadr_verify_publisher_at_distributor @target_server, @publisher_db,
		@publisher_linked_server
	if @retcode <> 0
		return 1
		
	-- Verify that the redirected publisher is a replication publisher
	--
	exec @retcode = sys.sp_hadr_verify_replication_publisher @target_server, @publisher_db,
		@publisher_linked_server
	if @retcode <> 0
		return 1          
				
	-- Verify that the published database subscribers of the original publisher are remote
	-- servers of the redirected publisher 
	--
	exec @retcode = sys.sp_hadr_verify_subscribers_at_publisher @original_publisher, @target_server, 
		@publisher_db, @publisher_linked_server
	if @retcode <> 0
		return 1 
	
	-- Drop the temporary linked server without raising an error
	--
	exec sys.sp_hadr_drop_linked_server @publisher_linked_server
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_validate_redirected_publisher] TO [public] AS [dbo]
GO
