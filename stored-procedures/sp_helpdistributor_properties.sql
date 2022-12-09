SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdistributor_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdistributor_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdistributor_properties]
WITH EXECUTE AS CALLER
AS
declare @retcode int

	-- Allow access if the user is 'sysadmin', member of 'db_owner' or 'repl_monitor'
	-- role in a distribution database, or in the PAL of a publication whose publisher
	-- uses this distributor.
	exec @retcode = sys.sp_MSrepl_DistributorPALAccess
	if (@retcode <> 0 or @@error <> 0)
	BEGIN
		DECLARE @login sysname
		SET @login = suser_sname()
		RAISERROR(21672, 16, -1, @login) 
		return (1)
	END 

	if exists (select name from msdb.sys.objects where name = 'MSdistributor')
	begin
		-- There is currently only one property, so this will work
		select 'heartbeat_interval' = convert(int, value) from msdb..MSdistributor where
			property = 'heartbeat_interval'
		return (0)
	end
	return (1)
GO
GRANT EXECUTE ON [sys].[sp_helpdistributor_properties] TO [public] AS [dbo]
GO
