SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgettranconflictrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgettranconflictrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgettranconflictrow]
	@tran_id [sysname],
	@row_id [sysname],
	@conflict_table [nvarchar](270),
	@is_subscriber [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
            ,@cmd nvarchar(4000)
            ,@whcmd nvarchar(4000)
            ,@unqualified_cft_tab sysname
            ,@publication sysname
            
    --
    -- get the publication name
    --
    if (@is_subscriber = 1)
    begin
    	--
	    -- check if the conflict table is owner qualified
	    --
	    select @unqualified_cft_tab = QUOTENAME(PARSENAME(@conflict_table, 1))
	    
        --
        -- we are on subscriber
        --
        select @publication = sagnt.publication
        from (MSsubscription_articles as sart join MSsubscription_agents as sagnt 
                on sart.agent_id = sagnt.id)
        where quotename(sart.cft_table) = @unqualified_cft_tab
    end
    else
    begin
        --
        -- we are on publisher
        --
        select @publication = p.name
        from ((sysarticles a join sysarticleupdates b 
            on a.pubid = b.pubid 
            and a.artid = b.artid) join syspublications p 
                on a.pubid = p.pubid)
        where b.conflict_tableid = OBJECT_ID(@conflict_table)
    end
    --
    -- Do PAL security check
    --
    exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
    if @retcode <> 0 or @@error <> 0
        return (1)
    --
    -- passed the security check
    --
    select @cmd = N'select * from ' + ISNULL(NULLIF(QUOTENAME(PARSENAME(@conflict_table, 2)) + N'.', N'.'), N'') + QUOTENAME(PARSENAME(@conflict_table, 1))
    if (@tran_id != N'%')
    begin
        if (@whcmd is null)
            select @whcmd = N'tranid = ' + QUOTENAME(@tran_id, '''')
        else
            select @whcmd = @whcmd + N' and tranid = ' + QUOTENAME(@tran_id, '''')
    end
    if (@row_id != N'%')
    begin
        if (@whcmd is null)
            select @whcmd = N'qcfttabrowid = ' + QUOTENAME(@row_id, '''')
        else
            select @whcmd = @whcmd + N' and qcfttabrowid = ' + QUOTENAME(@row_id, '''')
    end
    if (@whcmd is not null)
    begin
        select @cmd = @cmd + N' where ' + @whcmd
    end
    --
    -- execute the generated select
    --
    execute (@cmd)
    --
    -- all done
    --
end
GO
GRANT EXECUTE ON [sys].[sp_MSgettranconflictrow] TO [public] AS [dbo]
GO
