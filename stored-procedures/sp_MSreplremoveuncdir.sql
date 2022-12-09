SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplremoveuncdir]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplremoveuncdir] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplremoveuncdir]
	@dir [nvarchar](260),
	@ignore_errors [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int
	declare @local_dir nvarchar(260)
	declare @cmd nvarchar(1000)
	declare @machinename sysname
	set @retcode = 0
	--
	-- security check
	-- only sysadmin can execute this
	--
	if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	/* Null\Empty paths == no-op */
	if @dir is null or rtrim(@dir) = N''
		return (0)

	/* Path truncation check */
	if len(@dir) = 260
		return (0)

	/* 
	** We have to convert UNC to drive, otherwise will get 'Access denied' error in xp_cmdshell
	*/
	select @machinename = convert(sysname, SERVERPROPERTY('machinename'))
	EXEC @retcode = master.dbo.sp_MSunc_to_drive @unc_path = @dir, 
		@local_server = @machinename, @local_path = @local_dir OUTPUT
	IF @retcode <> 0 or @@ERROR <> 0 
		RETURN(1)

	/*
	** Delete directory in the distributor's directory.
	*/
	declare @local_dir_exists bit = 0
	begin try
		exec sys.sp_MSget_file_existence @local_dir, @local_dir_exists OUTPUT
		if @local_dir_exists = 1
		begin
			exec @retcode = master.sys.xp_delete_files @local_dir
		end
	end try
	begin catch
		set @retcode = 1
		if XACT_STATE() = -1 rollback tran
	END catch

	if @ignore_errors <> 1
	begin
		if @retcode <> 0
		begin
			raiserror(20015, 16, -1, @dir)
			return(1)
		end
	end

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplremoveuncdir] TO [public] AS [dbo]
GO
