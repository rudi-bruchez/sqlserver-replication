SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchecksharedagentforpublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchecksharedagentforpublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchecksharedagentforpublication]
	@publisher_id [int],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@publication_id int
				,@independent_agent int

	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

    -- Get the publication information 
    select @publication_id = publication_id
            ,@independent_agent = independent_agent 
    from dbo.MSpublications 
    where publisher_id = @publisher_id and
        publisher_db = @publisher_db and
        publication = @publication
    if @publication_id is NULL
    begin
        raiserror (20026, 16, -1, @publication)
        return (1)
    end
    --
    -- Perform PAL check with retrieved @publication_id
    --
    exec @retcode = sys.sp_MScheck_pull_access
                        @agent_type = 0, -- distrib agent
                        @publication_id = @publication_id
    if @@error <> 0 or @retcode <> 0
    begin    
        raiserror (15247, 16, -1)
        return (1)
    end
    --
    -- return the resultset
    --
    select 'runassharedagent' = case when (@independent_agent = 0) then 1 else 0 end
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSchecksharedagentforpublication] TO [public] AS [dbo]
GO
