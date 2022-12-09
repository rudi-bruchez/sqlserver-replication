SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_snapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_snapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_snapshot_agent]
	@agent_id [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 					int,
			@publisher					sysname,
			@publisher_security_mode 	int,
			@publisher_login 			sysname,
			@publisher_password 		nvarchar(524)

	-- 
	-- make sure this is a replication agent.
	-- if sessionproperty('replication_agent') != 1
	-- begin
	-- 	-- "You do not have sufficient permission to run this command."
	-- 	raiserror(14260, 16, -1)
	-- 	return 1 
	-- end
	-- 
	
	-- sysadmin or db_owner have access
	if is_srvrolemember('sysadmin') != 1 
		and is_member('db_owner') != 1
	begin
		-- "You do not have sufficient permission to run this command."
		raiserror(14260, 16, -1)
		return 1
	end
	
	-- retrieve the publisher server and database name
	select mssa.publisher_security_mode,
			mssa.publisher_login,
			sys.fn_repldecryptver4(mssa.publisher_password),
			case when serverproperty('EngineEdition') = 8 then mssa.job_login else null end,
			case when serverproperty('EngineEdition') = 8 then sys.fn_repldecryptver4(mssa.job_password) else null end
		from MSsnapshot_agents mssa
		where mssa.id = @agent_id
	if @@error <> 0 return 1

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_snapshot_agent] TO [public] AS [dbo]
GO
