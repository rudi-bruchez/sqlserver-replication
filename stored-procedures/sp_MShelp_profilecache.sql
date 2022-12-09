SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_profilecache]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_profilecache] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_profilecache]
	@profile_name [sysname]
WITH EXECUTE AS CALLER
AS
declare @profile_id int
	declare @retcode int

	--
	-- security check
	--
	exec @retcode = sys.sp_MSreplcheck_subscribe
	if @@ERROR <> 0 or @retcode <> 0
	begin
		return(1)
	end

	select @profile_id = NULL
	
	select parameter_name, value 
		from dbo.MSmerge_agent_parameters
		where profile_name = @profile_name
GO
GRANT EXECUTE ON [sys].[sp_MShelp_profilecache] TO [public] AS [dbo]
GO
