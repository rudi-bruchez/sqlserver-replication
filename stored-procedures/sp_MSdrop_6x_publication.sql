SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_6x_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_6x_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_6x_publication]
	@job_id [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
	declare @publisher sysname
	declare @publisher_db sysname
	declare @publication sysname
	declare @retcode int

    --
    -- security check
    -- only db_owner can execute this
    --
    if (is_member ('db_owner') != 1) 
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
        raiserror(21482, 16, -1, 'sp_MSdrop_6x_publication', 'distribution')
        return (1)
    end
    -- Get publication information
    select @publisher = srvname, @publisher_db = publisher_db, @publication = publication from 
        MSsnapshot_agents, MSreplservers where
        job_id = @job_id and
        srvid = publisher_id

	-- Remove the publication and snapshot agent
	exec @retcode = sys.sp_MSdrop_publication
		@publisher = @publisher,
		@publisher_db = @publisher_db,
		@publication = @publication 
	if @@ERROR <> 0 or @retcode <> 0
		return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_6x_publication] TO [public] AS [dbo]
GO
