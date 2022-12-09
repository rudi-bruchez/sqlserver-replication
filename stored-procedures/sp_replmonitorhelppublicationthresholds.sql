SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelppublicationthresholds]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelppublicationthresholds] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelppublicationthresholds]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@thresholdmetricname [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
		,@publisher_id int
		,@publication_id int

    --
    -- security check : replmonitor
    --
    if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    --
    -- security: Has to be executed from distribution database
    --
    if sys.fn_MSrepl_isdistdb (db_name()) != 1
    begin
    	raiserror (21482, 16, -1, 'sp_replmonitorhelppublicationthresholds', 'distribution')
    	return 1
    end

	-- Get publisher without port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

    --
    -- Validate @publisher
    --
    select @publisher_id = srvid
    from MSreplservers 
    where upper(srvname) = upper(@publisher)
    if (@publisher_id is null)
    begin
        raiserror(21618, 16, -1, @publisher)
        return 1
    end
    --
    -- validate publication
    --
    if not exists (select publication_id
                        from dbo.MSpublications 
                        where publisher_id = @publisher_id
                            and publisher_db = @publisher_db
                            and publication = @publication
                            and publication_type= case when (@publication_type is null) then publication_type else @publication_type end)
    begin
        raiserror(20026, 16, 1, @publication)
        return 1
    end
    --
    -- validate metric
    --
    if (@thresholdmetricname is not null)
    begin
        if not exists (select metric_id
                from msdb.dbo.MSreplmonthresholdmetrics
                where title = lower(@thresholdmetricname))
        begin
            raiserror(14200, 16, 2, '@thresholdmetricname')
            return 1
        end
    end
    --
    -- prepare the resultset to display
    --
    if @publication_type IS null
    select t.metric_id, m.title, cast(t.value as int) as value, t.shouldalert, t.isenabled
    from (dbo.MSpublicationthresholds as t join dbo.MSpublications as p
        on t.publication_id = p.publication_id 
        and p.publisher_id = @publisher_id
        and p.publisher_db = @publisher_db
        and p.publication = @publication) 
        join         
        msdb.dbo.MSreplmonthresholdmetrics as m
        on t.metric_id = m.metric_id
        and m.title = case when (@thresholdmetricname is null) then m.title
                            else lower(@thresholdmetricname) end
    else
     select t.metric_id, m.title, cast(t.value as int) as value, t.shouldalert, t.isenabled
    from (dbo.MSpublicationthresholds as t join dbo.MSpublications as p
        on t.publication_id = p.publication_id 
        and p.publisher_id = @publisher_id
        and p.publisher_db = @publisher_db
        and p.publication = @publication and p.publication_type=@publication_type) 
        join         
        msdb.dbo.MSreplmonthresholdmetrics as m
        on t.metric_id = m.metric_id
        and m.title = case when (@thresholdmetricname is null) then m.title
                            else lower(@thresholdmetricname) end
    --
    -- return
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelppublicationthresholds] TO [public] AS [dbo]
GO
