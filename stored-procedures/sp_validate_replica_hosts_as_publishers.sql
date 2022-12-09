SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validate_replica_hosts_as_publishers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validate_replica_hosts_as_publishers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validate_replica_hosts_as_publishers]
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
		@retcode int,
		@use_caller_credentials bit
		
   set @redirected_publisher = null
   set @target_server = null
   set @publisher_linked_server = null
   set @dbname = db_name()
   set @use_caller_credentials = 1
   
	-- Has to be executed from a distribution database
	--
	if (sys.fn_MSrepl_isdistdb (@dbname) <> 1)
	begin
		raiserror(21874, 16, -1, 'sys.sp_validate_replica_hosts_as_publishers', @dbname)
		return 1
	end	
		
	-- Verify input parameters are not NULL
	--
	if @original_publisher is null or
		@publisher_db is null
	begin
		raiserror (21875, 16, -1, 'sys.sp_validate_replica_hosts_as_publishers')
		return 1
	end
	
	-- Security check
	--
	if is_member(N'db_owner') <> 1
	begin
		exec @retcode = sys.sp_MSrepl_DistDBPALAccess @original_publisher
		
		if (@retcode <> 0) or (@@error <> 0)
		begin
			raiserror (21873, 16, -1, 'sys.sp_validate_replica_hosts_as_publishers')
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
		raiserror(21871, 10, 0, @original_publisher, @publisher_db);
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
		@redirected_publisher, @publisher_linked_server output, @use_caller_credentials
	if @retcode <> 0
	begin
		return 1
	end
	
	-- Query the availability group primary for the names of the member replicas associated
	-- with the publisher database and validate the host server for each replica as a
	-- replication publisher. 
	--
	exec @retcode = sys.sp_hadr_validate_replica_hosts_as_publishers @original_publisher, 
		@redirected_publisher, @publisher_db, @publisher_linked_server 
	
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_validate_replica_hosts_as_publishers] TO [public] AS [dbo]
GO
