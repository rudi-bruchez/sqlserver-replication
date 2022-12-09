SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_browsereplcmds]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_browsereplcmds] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_browsereplcmds]
	@xact_seqno_start [nchar](22),
	@xact_seqno_end [nchar](22),
	@originator_id [int],
	@publisher_database_id [int],
	@article_id [int],
	@command_id [int],
	@agent_id [int],
	@compatibility_level [int]
WITH EXECUTE AS CALLER
AS
declare @query nvarchar( 4000 )
		,@retcode			int
		,@dbname sysname

	select @dbname = db_name()
	if (sys.fn_MSrepl_isdistdb (@dbname ) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_browsereplcmds', 'distribution')
		return (1)
	end

	-- security check.
	-- User must be member of 'replmonitor' role in distribution database
	--
	exec @retcode = sys.sp_MSrepl_DistributorReplMonitorAccess @distribution_db = @dbname 
	if @retcode != 0 or @@error != 0
	    return (1)

	-- make sure that the start lsn and end lsn seq no are a valid hexstr
	if @xact_seqno_start is not null
	begin
		if(select sys.fn_isvalidhexstr(sys.fn_replreplacesinglequote(@xact_seqno_start))) <> 1
		begin
			raiserror(4334, 16, -1)
			return (1)
		end
	end
	
	if @xact_seqno_end is not null
	begin
		if(select sys.fn_isvalidhexstr(sys.fn_replreplacesinglequote(@xact_seqno_end))) <> 1
		begin
			raiserror(4334, 16, -1)
			return (1)
		end
	end

--first let's find out if we are returning cmds specific to an agent
if(@agent_id is not NULL)
begin
	if @xact_seqno_start is null
	begin
	    select @xact_seqno_start = N'0x00000000000000000000'
	end
	select @query = N'exec sys.sp_MSget_repl_commands ' + cast (@agent_id as nvarchar(12)) + N', ' + sys.fn_replreplacesinglequote(@xact_seqno_start ) + N', 0, ' + cast (@compatibility_level as nvarchar(12))
	exec sys.sp_printagentstatement @query
	return 0
end

--we know this is not specific to an agent, now go against the entire table.
if( @command_id is not null )
begin
    if( @xact_seqno_start is null or @publisher_database_id is null )
    begin
        raiserror( 21110, 16, -1 )
        return 1
    end
    else if @xact_seqno_start != @xact_seqno_end 
    begin
        raiserror( 21109, 16, -1 )
        return 1
    end
end

if @xact_seqno_start is null
begin
    select @xact_seqno_start = N'0x00000000000000000000'
end
if @xact_seqno_end is null
begin
    select @xact_seqno_end = N'0xFFFFFFFFFFFFFFFFFFFF'
end

select @query = N'select cmds.article_id, cast (cmds.partial_command as tinyint), cmds.command, cmds.xact_seqno, '
select @query = @query + 'cmds.xact_seqno, 0, cmds.command_id, cmds.type, orgs.srvname, orgs.dbname, '
select @query = @query + 'cast (cmds.hashkey as smallint), orgs.publication_id, orgs.dbversion, cmds.originator_lsn '
select @query = @query + 'from MSrepl_commands cmds left join MSrepl_originators orgs on cmds.originator_id = orgs.id '

if @command_id is not null
begin
    select @query = @query + N'where cmds.xact_seqno = ' + sys.fn_replreplacesinglequote(@xact_seqno_start )
end
else
begin
    select @query = @query + N'where cmds.xact_seqno >= ' + sys.fn_replreplacesinglequote(@xact_seqno_start) + N' and cmds.xact_seqno <= ' + sys.fn_replreplacesinglequote(@xact_seqno_end) 
end

if @originator_id is not null
begin
    select @query = @query + N' and cmds.originator_id = ' + convert( nvarchar, @originator_id )
end

if @publisher_database_id is not null
begin
    select @query = @query + N' and cmds.publisher_database_id = ' + convert( nvarchar, @publisher_database_id )
end

if @article_id is not null
begin
    select @query = @query + N' and cmds.article_id = ' + convert( nvarchar, @article_id )
end

if @command_id is not null
begin
	-- No need to use article_id and originator_id
    select @query = @query + N' and cmds.command_id >= ' + convert( nvarchar, @command_id )
    select @query = @query + N' and cmds.command_id <= ( select min( command_id ) from MSrepl_commands c '
    select @query = @query + N' where c.xact_seqno = ' +  sys.fn_replreplacesinglequote(@xact_seqno_start ) 
    select @query = @query + N' and c.publisher_database_id = ' + convert( nvarchar, @publisher_database_id )
    select @query = @query + N' and c.command_id >= ' + convert( nvarchar, @command_id )
    select @query = @query + N' and c.partial_command = 0 )'  
end

select @query = @query + N' order by cmds.originator_id, cmds.publisher_database_id, cmds.xact_seqno, cmds.article_id, cmds.command_id asc'


exec sys.sp_printstatement @query
GO
GRANT EXECUTE ON [sys].[sp_browsereplcmds] TO [public] AS [dbo]
GO
