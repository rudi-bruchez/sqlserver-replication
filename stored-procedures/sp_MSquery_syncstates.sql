SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSquery_syncstates]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSquery_syncstates] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSquery_syncstates]
	@publisher_id [smallint],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
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
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

    -- note:  obtain publisher_id via call to sp_MSvalidate_distpublisher

	select publication_id from MSsync_states 
	where publisher_id = @publisher_id 
	and publisher_db = @publisher_db
end
GO
GRANT EXECUTE ON [sys].[sp_MSquery_syncstates] TO [public] AS [dbo]
GO
