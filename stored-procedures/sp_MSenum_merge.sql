SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge]
	@name [nvarchar](100),
	@show_distdb [bit],
	@exclude_anonymous [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher sysname
	declare @publisher_id smallint
	declare @publisher_db sysname
	declare @subscriber sysname
	declare @subscriber_id smallint
	declare @subscriber_db sysname
	declare @subscriber_name sysname
	declare @subscription_type int
	declare @publication sysname
	declare @status int
	declare @start_time nvarchar(24)
	declare @time nvarchar(24)
	declare @duration int
	declare @comments nvarchar(255)
	declare @download_inserts int
	declare @download_updates int
	declare @download_deletes int
	declare @download_conflicts int
	declare @upload_inserts int
	declare @upload_updates int
	declare @upload_deletes int
	declare @upload_conflicts int
	declare @delivery_rate int
	declare @agent_name nvarchar(100)
	declare @error_id int
	declare @job_id binary(16)
	declare @local_job bit
	declare @profile_id int
	declare @agent_id int
	declare @last_timestamp binary(8)
	declare @offload_enabled bit
	declare @offload_server  sysname
		,@subscriber_type tinyint

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	create table #merge_agent (name nvarchar(100) NOT NULL, status int NOT NULL,
		publisher sysname NOT NULL, publisher_db sysname NOT NULL, publication sysname NULL,
		subscriber sysname NOT NULL, subscriber_db sysname NOT NULL, subscription_type int NULL,
		start_time nvarchar(24) NULL, time nvarchar(24) NULL, duration int NULL, 
		comments nvarchar(255) NULL, delivery_rate int NULL,
		download_inserts int NULL, download_updates int NULL, download_deletes int NULL,
		publisher_conficts int NULL, 
		upload_inserts int NULL, upload_updates int NULL, upload_deletes int NULL,
		subscriber_conficts int NULL, error_id int NULL, job_id binary(16) NULL,
		local_job bit NULL, profile_id int NOT NULL, agent_id int NOT NULL, last_timestamp binary(8) NOT NULL,
		offload_enabled bit NOT NULL, offload_server sysname NULL,
		subscriber_type tinyint NULL)

	declare hC CURSOR LOCAL FAST_FORWARD FOR
		select p.publisher_id, a.subscriber_id, a.publisher_db, a.subscriber_db, 
			p.publication, a.name, a.local_job, a.job_id, a.profile_id, a.id, a.subscriber_name, 
			offload_enabled, offload_server
			from dbo.MSmerge_agents a, dbo.MSpublications p  
			where 
			a.name LIKE @name and
			a.publisher_id = p.publisher_id and
			a.publisher_db = p.publisher_db and
			a.publication = p.publication and
			(@exclude_anonymous = 0 or a.anonymous_subid is null)

		for read only


	OPEN hC
	FETCH hC INTO @publisher_id, @subscriber_id, @publisher_db, @subscriber_db,
		@publication, @agent_name, @local_job, @job_id, @profile_id, @agent_id, @subscriber_name, 
		@offload_enabled, @offload_server

	WHILE (@@fetch_status <> -1)
	begin

		/* Initialize the values for no history case */
		select @status = 0,
			@start_time = NULL,
			@time = NULL, 
			@duration = NULL, 
			@comments = NULL,
			@download_inserts = 0,
			@download_deletes = 0,
			@download_updates = 0,
			@download_conflicts = 0,
			@upload_inserts = 0,
			@upload_deletes = 0,
			@upload_updates = 0,
			@upload_conflicts = 0,
			@delivery_rate = 0,
			@error_id = NULL, 
			@last_timestamp = 0x00000000

		select @status = isnull(ms.runstatus,0),
			@start_time = sys.fn_replformatdatetime(ms.start_time),
			@time = sys.fn_replformatdatetime(ms.end_time), 
			@duration = ms.duration, 
			@comments = mh.comments,
			@download_inserts = ms.download_inserts,
			@download_deletes = ms.download_deletes,
			@download_updates =  ms.download_updates,
			@download_conflicts =  ms.download_conflicts,
			@upload_inserts = ms.upload_inserts,
			@upload_deletes = ms.upload_deletes,
			@upload_updates =  ms.upload_updates,
			@upload_conflicts =  ms.upload_conflicts,
			-- Note: return average rate here !!! delivery_rate column is current rate
			@delivery_rate = ms.delivery_rate, 
			@error_id = mh.error_id, 
			@last_timestamp = ms.timestamp
			from dbo.MSmerge_history mh with (READPAST), dbo.MSmerge_sessions ms with (READPAST)
			where
				mh.agent_id = @agent_id and
				mh.timestamp = (select max(timestamp) from dbo.MSmerge_history mh2 with (READPAST) 
					where mh2.agent_id = @agent_id)
				and
				ms.agent_id= @agent_id and
				ms.session_id = (select top 1 session_id from dbo.MSmerge_sessions ms2 with (READPAST) 
									where ms2.agent_id = @agent_id
									order by session_id desc)

        select @publisher = srvname from MSreplservers where srvid = @publisher_id

        -- For non anonymous agents, @subscriber_name is null 
        if @subscriber_name is NULL
            begin
                select @subscriber = srvname from MSreplservers where srvid = @subscriber_id
                if @local_job = 1 select @subscription_type = 0
                    else select @subscription_type = 1
				select @subscriber_type = type from MSsubscriber_info where
					UPPER(publisher) = UPPER(@publisher) and
					UPPER(subscriber) = UPPER(@subscriber)
			end
		else 
			begin
				select @subscriber = @subscriber_name
				select @subscriber_db = @subscriber_db + '-' +  convert(nvarchar(30), @agent_id)
				select @subscription_type = 2   -- anonymous type
			end
		
		insert into #merge_agent values (@agent_name, @status, @publisher,
			@publisher_db, @publication, @subscriber, @subscriber_db, @subscription_type,
			@start_time, @time, @duration, @comments, @delivery_rate,
			@download_inserts, @download_updates, @download_deletes, 
			@download_conflicts,
			@upload_inserts, @upload_updates, @upload_deletes, 
			@upload_conflicts,
			@error_id, @job_id, @local_job, @profile_id, @agent_id, @last_timestamp,
			@offload_enabled, @offload_server, @subscriber_type)

		FETCH hC INTO @publisher_id, @subscriber_id, @publisher_db, @subscriber_db,
			@publication, @agent_name, @local_job, @job_id, @profile_id,
			@agent_id, @subscriber_name, @offload_enabled, @offload_server
		end

	if @show_distdb = 0
		select * from #merge_agent 
	else 
		select 'dbname' = DB_NAME(), * from #merge_agent

	drop table #merge_agent
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge] TO [public] AS [dbo]
GO
