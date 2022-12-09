SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_logreader_agentid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_logreader_agentid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_logreader_agentid]
	@publisher_id [smallint],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
	declare @publisher sysname
	declare @job_id binary(16)
	declare @qv_package	varchar(20)
	declare @desk_top		int
	declare @license_value int
	declare @qv_value_package int

    --
    -- security check
    -- only db_owner can execute this
    --
    if (is_member ('db_owner') != 1) 
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

	select @qv_package = '845129433'
	select @license_value = 0 
	select @desk_top = 3
			
	exec @qv_value_package = sys.sp_MSinstance_qv @qv_package
	if @@ERROR<>0 
		begin
			raiserror(20089, 16, -1)
			return (1)
		end
	if @qv_value_package = 1		 --- 1 means desktop
		select @license_value = @desk_top   -- to be consistent with all other compenents.

	select logreaderAgent.id, logreaderAgent.name, @license_value, profileName.profile_name 
		from MSlogreader_agents as logreaderAgent 
		INNER JOIN msdb..MSagent_profiles as profileName 
		on logreaderAgent.profile_id = profileName.profile_id
		where 
		logreaderAgent.publisher_id = @publisher_id and 
		logreaderAgent.publisher_db = @publisher_db


	return(0)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_logreader_agentid] TO [public] AS [dbo]
GO
