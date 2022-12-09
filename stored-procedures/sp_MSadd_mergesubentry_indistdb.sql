SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_mergesubentry_indistdb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_mergesubentry_indistdb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_mergesubentry_indistdb]
	@publisher_id [smallint],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [tinyint],
	@sync_type [tinyint],
	@status [tinyint],
	@description [nvarchar](255),
	@subid [uniqueidentifier],
	@subscriber_version [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publication_id int
	declare @retcode int
	declare @cur_version int, @rowcount int

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_anonsubentry_indistdb', 'distribution')
		return (1)
	end
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)
		
	select @publication_id = publication_id
		from dbo.MSpublications where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @publication_id is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end
	
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_type = 1, -- merge agent
		@publication_id = @publication_id
	if @@error <> 0 or @retcode <> 0
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end
   
	select top 1 @cur_version = subscriber_version 
	from dbo.MSmerge_subscriptions where subid = @subid
	select @rowcount = @@rowcount
		
	if @rowcount = 0
	begin
		-- if another entry exists but with an incorrect subid, just update the subid.
		if exists (select * from dbo.MSmerge_subscriptions 
					where upper(publisher) = upper(@publisher)
					and publisher_db = @publisher_db
					and publication_id = @publication_id
					and upper(subscriber) = upper(@subscriber)
					and subscriber_db = @subscriber_db)
		begin
			update dbo.MSmerge_subscriptions
			set status = @status,
				subscription_type = @subscription_type,
				subscription_time = getdate(), 
				description = @description, 
				subid = @subid,
				subscriber_version = case when subscriber_version is null then @subscriber_version else subscriber_version end
			where upper(publisher) = upper(@publisher)
					and publisher_db = @publisher_db
					and publication_id = @publication_id
					and upper(subscriber) = upper(@subscriber)
					and subscriber_db = @subscriber_db
					and subscription_type = @subscription_type
			
			if @@error <> 0
				return 1
		end
		else
		begin
		
			insert into dbo.MSmerge_subscriptions (publisher_id, publisher_db, publication_id,
					subscriber_id, subscriber_db, subscription_type, sync_type, status, 
					subscription_time, description, publisher, subscriber, subid, subscriber_version)
				values (@publisher_id, @publisher_db, @publication_id, NULL, @subscriber_db, 
						@subscription_type, @sync_type, @status, getdate(), @description,
						@publisher,	@subscriber, @subid, @subscriber_version)
			
			if @@error <> 0
				return 1
		end
	end
	else if @cur_version is null and @subscriber_version is not null
	begin
		update dbo.MSmerge_subscriptions
		set subscriber_version = @subscriber_version
		where subid = @subid
	end
	
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_mergesubentry_indistdb] TO [public] AS [dbo]
GO
