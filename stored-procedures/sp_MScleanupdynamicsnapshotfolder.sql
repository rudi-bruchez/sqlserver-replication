SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanupdynamicsnapshotfolder]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanupdynamicsnapshotfolder] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanupdynamicsnapshotfolder]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@dynamic_snapshot_location [nvarchar](260),
	@partition_id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
	declare @publisher_id int
	declare @publication_id int
	
	set @retcode = 0
	set @publisher_id = null
	set @publication_id = null

	set @dynamic_filter_login = coalesce(@dynamic_filter_login, N'')
	set @dynamic_filter_hostname = coalesce(@dynamic_filter_hostname, N'')

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member('db_owner') != 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSdrop_publication', 'distribution')
		return (1)
	end
	
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- Make sure publication exists
	select @publication_id = publication_id
		from dbo.MSpublications where publication = @publication and
		publisher_id = @publisher_id and publisher_db = @publisher_db
	if @publication_id is NULL
	begin
		-- We don't know whether or not it is a third party or not so we can not 
		-- return error.
		-- raiserror(20026, 16, -1, @publication)
		-- return (1)
		return (0)
	end
   
	if @dynamic_snapshot_location is null or rtrim(@dynamic_snapshot_location) = N''
		return (0)

	declare @publication_snapshot_folder nvarchar(260)
	declare @pathSeparator nvarchar(2)
	
	select @pathSeparator = CAST(SERVERPROPERTY('pathseparator') as nvarchar(2))


	if substring(@dynamic_snapshot_location, len(@dynamic_snapshot_location), 1) <> @pathSeparator
	begin
		set @dynamic_snapshot_location = @dynamic_snapshot_location + @pathSeparator
	end
	
	exec @retcode = sys.sp_MSreplremoveuncdir @dynamic_snapshot_location
	if @retcode <> 0 or @@error <> 0
   			return(1)    

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MScleanupdynamicsnapshotfolder] TO [public] AS [dbo]
GO
