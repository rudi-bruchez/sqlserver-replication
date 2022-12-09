SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanup_agent_entry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanup_agent_entry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanup_agent_entry]
WITH EXECUTE AS CALLER
AS
declare @min_valid_day 		datetime
	, @publisher_id 		int
	, @subscriber_id 		int
	, @publication 			sysname
	, @publication_id		int
	, @publisher_db 		sysname
	, @subscriber_db 		sysname
	, @retention 			int
	, @publication_type 	int
	, @agent_id			int
	, @num_dropped	int
	, @retcode int
	, @retention_period_unit tinyint

    set nocount on
    select @num_dropped = 0

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

	declare PC CURSOR LOCAL FAST_FORWARD for 
		select distinct publisher_id, publisher_db, publication, retention, publication_type, 
			retention_period_unit, publication_id
		from MSpublications
		where retention<>0
	open PC
	fetch PC into @publisher_id, @publisher_db, @publication, @retention, @publication_type, 
		@retention_period_unit, @publication_id
	while (@@fetch_status <> -1)
    begin    
		if @publication_type = 2  --merge publication
		begin
    		select @min_valid_day = sys.fn_add_units_to_date(-@retention, @retention_period_unit, getdate())

		    declare hC CURSOR LOCAL FAST_FORWARD FOR 
				select msa.id from dbo.MSmerge_agents msa
				where msa.creation_date < @min_valid_day
    			and not exists 
    			(
    				select * from dbo.MSmerge_sessions sess
    				where sess.agent_id = msa.id 
    				and sess.end_time > @min_valid_day
    			)
    			and msa.publisher_id = @publisher_id
    			and msa.publisher_db = @publisher_db
    			and msa.publication = @publication   
	    		and msa.anonymous_subid is not null		-- Only do this for anonymous agents
				and not exists 
				(
					select * from dbo.MSmerge_subscriptions mss
					where mss.publisher_id = @publisher_id
					and mss.publisher_db = @publisher_db
    				and mss.publication_id = @publication_id
    				and upper(mss.subscriber) = upper(msa.subscriber_name)
    				and mss.subscriber_db = msa.subscriber_db
    				and mss.subscriber_version >= 90
    			)
			for read only
			open hC
			fetch hC into @agent_id
			while (@@fetch_status <> -1)
			begin
				exec @retcode = sys.sp_MSdrop_merge_agentid @agent_id
				if @retcode <> 0 or @@error <> 0
					return (1)
				select @num_dropped = @num_dropped + 1
				fetch hC into @agent_id
			end
			close hC
			deallocate hC
		end
   		else if @publication_type in (0,1) --Tran level publication
  			begin  
    			select @min_valid_day = dateadd(hour, @retention * (-1), getdate())    
				-- Only do this for anonymous agents
			    declare hC CURSOR LOCAL FAST_FORWARD FOR 
					select id from MSdistribution_agents where creation_date < @min_valid_day
						and not exists (select * from MSdistribution_history where agent_id = id and time > @min_valid_day)
						and publisher_id=@publisher_id
    					and publisher_db = @publisher_db
    					and publication = @publication            
	    				-- Only do this for anonymous agents
						and subscriber_name is not null         	            	
				for read only
				open hC
				fetch hC into @agent_id
				while (@@fetch_status <> -1)
				begin
					exec @retcode = sys.sp_MSdrop_distribution_agentid @agent_id
					if @retcode <> 0 or @@error <> 0
						return (1)
					select @num_dropped = @num_dropped + 1
					fetch hC into @agent_id
				end
			close hC
			deallocate hC
        	end
      	fetch PC into @publisher_id, @publisher_db, @publication, @retention, @publication_type, 
      		@retention_period_unit, @publication_id
    end
    close PC
    deallocate PC
	if @num_dropped > 0
		RAISERROR(20597, 10, -1, @num_dropped) 
   	return (0)
FAILURE:
    close PC
    deallocate PC
   	return (1)		
GO
GRANT EXECUTE ON [sys].[sp_MScleanup_agent_entry] TO [public] AS [dbo]
GO
