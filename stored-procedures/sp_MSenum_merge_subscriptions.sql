SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge_subscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge_subscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge_subscriptions]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@exclude_anonymous [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @subscriber sysname
	declare @subscriber_db sysname
	declare @subscriber_name sysname
	declare @type int
	declare @status int
	declare @agent_name nvarchar(100)
	declare @subscriber_id smallint
	declare @publisher_id smallint
	declare @start_time nvarchar(24)
	declare @time nvarchar(24)
	declare @duration int
	declare @comments nvarchar(255)
	declare @delivery_rate float
	declare @error_id int
	declare @publication_id int
	declare @download_inserts int
	declare @download_updates int
	declare @download_deletes int
	declare @download_conflicts int
	declare @upload_inserts int
	declare @upload_updates int
	declare @upload_deletes int
	declare @upload_conflicts int
	declare @job_id binary(16)
	declare @local_job bit
	declare @profile_id int
	declare @agent_id int
	declare @last_timestamp binary(8)
	declare @offload_enabled bit
	declare @offload_server sysname
		,@subscriber_type tinyint
	declare @anonymous_subid uniqueidentifier

	set nocount on

    --
    -- security check
    -- only replmonitor can execute this
    --
    if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
    
    select @publisher_id = srvid from MSreplservers where
       UPPER(srvname) = UPPER(@publisher)

	select @publication_id = publication_id from dbo.MSpublications where 
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			publication_type = 2 -- Merge 

	create table #merge_subscriptions (subscriber sysname NOT NULL,  status int NOT NULL, 
		subscriber_db sysname NOT NULL, type int NOT NULL, agent_name nvarchar(100) NOT NULL, last_action nvarchar(255) NULL, 
		action_time nvarchar(24) NULL, start_time nvarchar(24) NULL, duration int NULL, 
		delivery_rate float NULL,
		download_inserts int NULL, download_updates int NULL, download_deletes int NULL,
		publisher_conficts int NULL, 
		upload_inserts int NULL, upload_updates int NULL, upload_deletes int NULL,
		subscriber_conficts int NULL, error_id int NULL, job_id binary(16) NULL,
		local_job bit NULL, profile_id int NOT NULL, 
		agent_id int NOT NULL, last_timestamp binary(8) NOT NULL, offload_enabled bit NOT NULL, 
		offload_server sysname NULL, subscriber_type tinyint NULL)
	
	-- This is to force all queries to return rows ordered by job_id
	create unique clustered index ucmerge_subscriptions ON #merge_subscriptions (agent_id)

	declare hC CURSOR LOCAL FAST_FORWARD FOR select subscriber_id, subscriber_db, name, job_id, local_job, profile_id, id, subscriber_name,
													offload_enabled, offload_server, anonymous_subid
								from dbo.MSmerge_agents  
								 where publisher_id = @publisher_id and publisher_db = @publisher_db and publication = @publication  and 
									(@exclude_anonymous = 0 or anonymous_subid is null)
							for read only
	open hC
	fetch hC into  @subscriber_id, @subscriber_db, @agent_name, @job_id, @local_job, @profile_id, @agent_id, @subscriber_name, @offload_enabled,
				   @offload_server, @anonymous_subid
	while (@@fetch_status <> -1)
	begin

		if @anonymous_subid is not NULL 
			begin
				select @subscriber = @subscriber_name
				select @subscriber_db = @subscriber_db + '-' + convert(nvarchar(30), @agent_id)
				select @type = 2   --anonymous subscription
			end
		else
			begin
		  if @subscriber_id is not NULL 
        	      select @subscriber = srvname from MSreplservers where srvid=@subscriber_id
        	  else
        	      select @subscriber = @subscriber_name
                select @type = subscription_type from dbo.MSmerge_subscriptions  
                    where publisher_id = @publisher_id and
                        publisher_db = @publisher_db and
                        publication_id = @publication_id and
                        UPPER(subscriber) = UPPER(@subscriber) and
                        subscriber_db = @subscriber_db
				select @subscriber_type = type from MSsubscriber_info where
					UPPER(publisher) = UPPER(@publisher) and
					UPPER(subscriber) = UPPER(@subscriber)
			end
			
		-- Get the status of the agent
		select @status = 0 
		select  @start_time = NULL,
			@time = NULL, 
			@duration = NULL, 
			@comments = NULL,
			@download_inserts = NULL,
			@download_deletes = NULL,
			@download_updates =  NULL,
			@download_conflicts =  NULL,
			@upload_inserts = NULL,
			@upload_deletes = NULL,
			@upload_updates =  NULL,
			@upload_conflicts =  NULL,
			@delivery_rate = NULL, 
			@error_id = NULL,
			@last_timestamp = 0x00000000
				
		select @status = isnull(ms.runstatus,0),
			@start_time = sys.fn_replformatdatetime(ms.start_time),
			@time = sys.fn_replformatdatetime(ms.end_time), 
			@duration = ms.duration, 
			@comments = rh.comments,
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
			@error_id = rh.error_id, @last_timestamp = ms.timestamp
			from dbo.MSmerge_sessions ms with (READPAST), dbo.MSmerge_history rh with (READPAST)
			where
				ms.agent_id = @agent_id and
				ms.session_id = (select top 1 session_id from dbo.MSmerge_sessions with (READPAST) 
					where agent_id = @agent_id order by session_id desc) and
		  rh.agent_id = @agent_id and
		  rh.session_id=ms.session_id 
					
/* Not currently working Build 351
				timestamp = (select top 1 timestamp from dbo.MSmerge_history with (READPAST) 
					where agent_id = @agent_id
					order by timestamp DESC) 
*/
		
			insert into #merge_subscriptions values ( @subscriber, @status, @subscriber_db,
				@type, @agent_name, @comments, @time, @start_time, @duration,
				@delivery_rate, 
				@download_inserts, @download_updates, @download_deletes, 
				@download_conflicts,
				@upload_inserts, @upload_updates, @upload_deletes, 
				@upload_conflicts,
				@error_id, @job_id, @local_job, @profile_id, @agent_id, @last_timestamp,
				@offload_enabled, @offload_server, @subscriber_type)
		

		fetch hC into  @subscriber_id, @subscriber_db, @agent_name, @job_id, @local_job, @profile_id, @agent_id, @subscriber_name,
					   @offload_enabled, @offload_server, @anonymous_subid
	  end

	select * from #merge_subscriptions order by job_id asc

	drop table #merge_subscriptions
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge_subscriptions] TO [public] AS [dbo]
GO
