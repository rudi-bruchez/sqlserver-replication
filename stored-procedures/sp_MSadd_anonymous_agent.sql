SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_anonymous_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_anonymous_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_anonymous_agent]
	@publisher_id [int],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_db [sysname],
	@subscriber_name [sysname],
	@anonymous_subid [uniqueidentifier] OUTPUT,
	@agent_id [int] OUTPUT,
	@reinitanon [bit]
WITH EXECUTE AS CALLER
AS
begin
/*
** This stored procedure does not really add a job at distribution database;
** if add a row in MSdistribution_agent table for anonymous subscription for the 
** purpose of history logging
*/

   set nocount on
   declare @distribution_type smallint
			,@profile_id int
			,@subscriber_id smallint
			,@retcode int
			,@publication_id int
			,@virtual_agent_id int
			,@anonymous_agent_id int
			,@virtual smallint
			,@virtual_anonymous smallint
			,@new_agent_id int
			,@anonymous int
			,@publisher_database_id int
			,@allow_anonymous bit
			,@publication_type int
			,@merge_publication_type int
			,@publisher sysname
   
   select @publication_type = NULL
			,@merge_publication_type = 2
			,@virtual = -1
			,@virtual_anonymous = -2
			,@anonymous = 2

   
	-- Check to see if the publication is valid and allow anonymous
	select @publication_id = publication_id, @allow_anonymous = allow_anonymous, @publication_type = publication_type
	from dbo.MSpublications where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication 

	
	if @subscriber_name is null
		select @subscriber_name = N''

	-- Get virtual ids
	select top 1 @virtual_agent_id = agent_id, 
		@publisher_database_id = publisher_database_id from dbo.MSsubscriptions where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id and
		subscriber_id = @virtual

	select top 1 @anonymous_agent_id = agent_id from dbo.MSsubscriptions where
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication_id = @publication_id and
		subscriber_id = @virtual_anonymous

	-- Security check
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_id =  @anonymous_agent_id,
		@agent_type = 0 -- distribution agent   
	if @retcode <> 0 or @@error <> 0
		return (1)

	if @publication_id is null
	begin
		RAISERROR (21040, 16, -1, @publication)
		return 1
	end

	if @publication_type = @merge_publication_type
	begin
		RAISERROR(21132, 16, -1, @publication)
		return 1
	end

	if @allow_anonymous = 0
	begin
		RAISERROR (21084, 16, -1, @publication)
		return 1   
	end


	/*
	**  To return two more parameters for the purpose of anonymous monitoring
	** 
	** If @anonymous_subid is null, this is a new anonymous subscription; A new row would be inserted in MSdistribution_agents.
	** And its id (identity) and newly generated ID will be returned; The new ID would be used in subscriber side.
	*/
	select @subscriber_id = 0   -- for anonymous subscribers, ID is always 0

	select @agent_id = id from MSdistribution_agents 
	where anonymous_subid = @anonymous_subid
	
	IF @agent_id is null
	BEGIN
		if @anonymous_subid is not NULL and @anonymous_subid <> 0x00
		   and @reinitanon = 0
		begin
			-- Agent has be cleaned up, return error.
			raiserror(21072, 16, -1)
			return(1)
		end
		-- Generate a new subid only when the subscription is not 
		-- reinitialized
		if @reinitanon = 0
		begin
			select @anonymous_subid = newid()
		end
		SELECT @distribution_type = 3

		SELECT @profile_id = profile_id
		FROM msdb..MSagent_profiles
		WHERE agent_type = @distribution_type
			AND def_profile = 1

        IF @profile_id IS NULL
        RETURN (1)
        --
        -- SKU based subscription count check
        -- Skip this check for snapshot publications
        --
        if (@publication_type != 1)
        begin
            select @publisher = srvname
            from MSreplservers
            where srvid = @publisher_id
            exec @retcode = sys.sp_MScheck_subscription_count_internal @mode=0 
                                            ,@publisher = @publisher
                                            ,@about_to_insert_new_subscription = 1
            if (@retcode != 0 or @@error != 0)
                return 1
        end
        --
        -- Add entry to Distribution agents
        --
        INSERT into MSdistribution_agents (name, publisher_database_id, publisher_id, publisher_db, publication, 
                    subscriber_id, subscriber_db, subscription_type, local_job, job_id, subscription_guid, profile_id, anonymous_subid, 
                    subscriber_name, virtual_agent_id, anonymous_agent_id)
                    
             VALUES (convert(nvarchar(40), @anonymous_subid), @publisher_database_id, @publisher_id, @publisher_db, @publication, 
                        @subscriber_id, @subscriber_db, @anonymous, 0, @anonymous_subid,
                        @anonymous_subid, @profile_id, @anonymous_subid, @subscriber_name,
                        @virtual_agent_id, @anonymous_agent_id)
        select @agent_id = @@identity
    END
end        
GO
GRANT EXECUTE ON [sys].[sp_MSadd_anonymous_agent] TO [public] AS [dbo]
GO
