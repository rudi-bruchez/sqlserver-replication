SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_snapshot_dirs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_snapshot_dirs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_snapshot_dirs]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	declare @snapshot_bit int
	declare @directory_type int
	declare @alt_directory_type int
	declare @publisher_database_id int

	declare @dir nvarchar(512)
	declare @command_id int
	declare @xact_seqno varbinary(16)

	select @snapshot_bit = 0x80000000
	select @directory_type = 7
	select @alt_directory_type = 25

	-- Sysadmin check
	if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	--
	-- security check
	-- sysadmin check is done in sp_MSreplremoveuncdir
	--
	declare  hCdirs  CURSOR LOCAL FAST_FORWARD FOR select CONVERT(nvarchar(512), command),
		xact_seqno, command_id, publisher_database_id
		from MSrepl_commands where
		((type & ~@snapshot_bit) = @directory_type) or
		((type & ~@snapshot_bit) = @alt_directory_type)
	for read only

	open hCdirs
	fetch hCdirs into @dir, @xact_seqno, @command_id, @publisher_database_id
	while (@@fetch_status <> -1)
	begin
		--
		-- Need to map unc to local drive for access problem
		-- Security check is done in sp_MSreplremoveuncdir
		--
		exec @retcode = sys.sp_MSreplremoveuncdir @dir
		/* Abort the operation if the delete fails */
		if (@retcode <> 0 or @@error <> 0)
			return (1)

		delete MSrepl_commands where 
			publisher_database_id = @publisher_database_id and
			xact_seqno = @xact_seqno and
			command_id = @command_id

		fetch hCdirs into @dir, @xact_seqno, @command_id, @publisher_database_id
	end
	close hCdirs
	deallocate hCdirs
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_snapshot_dirs] TO [public] AS [dbo]
GO
