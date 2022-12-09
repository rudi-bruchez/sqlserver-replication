SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_snapshot_sd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_snapshot_sd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_snapshot_sd]
	@name [nvarchar](100),
	@time [datetime]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @start_time datetime
	declare @time_up datetime
	declare @publisher_id smallint
	declare @publisher_db sysname
	declare @publication sysname

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	IF @time IS NULL
		select @time = GETDATE()
	/* 
	** If @name is given, get its publisher and subscriber pair
	** Note: param will be overwritten
	** If @name is NOT given, use provided param.
	*/
	SELECT @publisher_id = pub.publisher_id, @publisher_db = pub.publisher_db, 
		@publication = pub.publication
		from
		MSsnapshot_agents agent, dbo.MSpublications pub
		where 
		name LIKE @name and
		agent.publisher_id = pub.publisher_id and
		agent.publication = pub.publication and
		agent.publisher_db = pub.publisher_db
	
	/*
	** Minute-approximate @time can be used.
	**
	** Note: The select only return datetime data with minute precisio
	*/
	IF  DATEPART(second, @time) = 0 AND
		DATEPART(millisecond, @time) = 0
	BEGIN
		SELECT @time_up = DATEADD(second, +59, @time)
		SELECT @time_up = DATEADD(millisecond, +999, @time)
	END
	ELSE
		SELECT @time_up = @time
		

	select top 1 @start_time = sh.start_time            
		 from MSsnapshot_history sh with (READPAST), MSsnapshot_agents sa
		where
		sa.publisher_id = @publisher_id and
		sa.publisher_db = @publisher_db and
		sa.publication  = @publication and
		sh.agent_id = sa.id and
		sh.time <= @time_up 
		order by sh.timestamp DESC

	select sh.runstatus, 
		'time' = sys.fn_replformatdatetime(sh.time), 
		sh.comments, 
		sh.duration, 
		sh.delivery_rate, 
		sh.delivered_commands,
		sa.name, 
		sh.error_id         
		from MSsnapshot_history sh with (READPAST), MSsnapshot_agents sa
		where
		sa.publisher_id = @publisher_id and
		sa.publisher_db = @publisher_db and
		sa.publication = @publication and 
		sh.agent_id = sa.id and
		sh.start_time = @start_time 
		order by sh.timestamp desc
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_snapshot_sd] TO [public] AS [dbo]
GO
