SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrefresh_anonymous]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrefresh_anonymous] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrefresh_anonymous]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 		int
	declare @publisher_id	int
	declare @success		int
	declare @agent_id		int

    --
    -- security check
    -- only db_owner can execute this
    --
    if (is_member ('db_owner') != 1) 
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    
    SELECT @publisher_id = NULL 
    SELECT @publisher_id = srvid FROM MSreplservers WHERE UPPER(@publisher) = UPPER(srvname)  
    IF @publisher_id IS NULL
    BEGIN
        RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
        return (1)
    END
    select @success = 2 --agent history status

	select @agent_id = id from dbo.MSmerge_agents where 
		anonymous_subid is not NULL and --touch anonymous only
		publication like @publication and 
		publisher_id=@publisher_id and 
		publisher_db=@publisher_db

	update TOP(1) dbo.MSmerge_sessions set end_time=getdate() where agent_id=@agent_id and runstatus=@success
	if @@ERROR<>0
		return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSrefresh_anonymous] TO [public] AS [dbo]
GO
