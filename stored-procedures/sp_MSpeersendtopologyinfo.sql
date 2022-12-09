SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeersendtopologyinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeersendtopologyinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeersendtopologyinfo]
	@request_id [int],
	@originator [sysname],
	@originator_db [sysname],
	@originator_publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode		int,
			@cmd			nvarchar(max),
			@info_cmd		nvarchar(max),
			@response_srvr	sysname,
			@response_db	     sysname,
			@connection_info	xml,
			@distributor         sysname,
			@distributordb     sysname,
			@response_originator_id int,
			@response_conflict_retention int

	-- security check for subscriber
	-- Though the work below is related to a publisher, we use 
	-- a check for the subscriber because this is normally executed
	-- by the distribution agent at a subscriber (republisher).
	-- this should only be used by peer to peer subscribers.
	exec @retcode = sys.sp_MSreplcheck_subscribe 
       if @@error <> 0 or @retcode <> 0 
       begin
           return 1
       end

	select @cmd = NULL,
			@response_srvr = publishingservername(),
			@response_db = db_name()

	-- get the distributor information
	exec @retcode = sp_helpdistributor @distributor=@distributor out, @distribdb = @distributordb out
       if @@error <> 0 or @retcode <> 0 
       begin
           return 1
       end

	-- the topology information query
	select @info_cmd = N'set @p = (
			select * from (
				select 1 as Tag,
						NULL as Parent,
						'+quotename(@distributor,'''')+N' as [Publisher!1!Distributor],
						'+quotename(@distributordb,'''')+N' as [Publisher!1!DistributorDatabase],
						NULL as [Publication!2!Name],
						NULL as [Subscription!3!SubscriberName],
						NULL as [Subscription!3!SubscriberDatabase],
						NULL as [Subscription!3!SubscriptionType]
				union all
				select 2,1,
						'+quotename(@distributor,'''')+N' as [Publisher!1!Distributor],
						'+quotename(@distributordb,'''')+N' as [Publisher!1!DistributorDatabase],
						p.name,
						NULL,
						NULL,
						NULL
					from syspublications as p
					group by p.name
				union all
				select 3,2,
						'+quotename(@distributor,'''')+N' as [Publisher!1!Distributor],
						'+quotename(@distributordb,'''')+N' as [Publisher!1!DistributorDatabase],
						p.name,
						s.srvname,
						s.dest_db,
						s.subscription_type
					from syspublications as p join sysarticles as a
							on p.pubid = a.pubid
						join syssubscriptions as s
							on a.artid = s.artid
					where s.srvid >= 0
			) as universal_table
			order by [Publisher!1!Distributor],[Publisher!1!DistributorDatabase],[Publication!2!Name],[Subscription!3!SubscriberName],[Subscription!3!SubscriberDatabase],[Subscription!3!SubscriptionType]
			for xml explicit
			)';

	select @response_originator_id = case when originator_id is NULL then 0 else originator_id end, 
		@response_conflict_retention = case when conflict_retention is NULL then 0 else conflict_retention end
	from syspublications  
	where name = @originator_publication

	begin transaction tr_sp_MSpeersendtopologyinfo
	save transaction tr_sp_MSpeersendtopologyinfo

	exec sp_executesql
		@stmt = @info_cmd,
		@params = N'@p as xml output',
		@p = @connection_info output;

	if @@error <> 0 or @retcode <> 0
		goto FAILURE

	select @cmd = N'if object_id(N''sys.sp_MSpeerapplytopologyinfo'', ''P'') is not null '+
				 N'exec sys.sp_MSpeerapplytopologyinfo @request_id=' + cast(@request_id as nvarchar) +
																	N',@originator=N' + quotename(@originator, '''') +
																	N',@originator_db=N' + quotename(@originator_db, '''') +
																	N',@response_srvr=N' + quotename(@response_srvr, '''') +
																	N',@response_db=N' + quotename(@response_db, '''')+
																	N',@connection_info=N' + N''''+replace(convert(nvarchar(max), @connection_info), '','''')+N'''' +
																	N',@response_srvr_version=' + cast(@@microsoftversion as nvarchar) +
																	N',@response_originator_id=' + cast(@response_originator_id as nvarchar) +
																	N',@response_conflict_retention=' + cast(@response_conflict_retention as nvarchar)

	-- if we are on the originator, then there is no need to forward the cmd, just execute it
	if UPPER(@originator) = UPPER(@response_srvr)
			and @originator_db = @response_db
	begin
		exec @retcode = sp_executesql @stmt = @cmd
	end
	-- if we are not on the originator then we do need to forward the cmd
	else
	begin
		exec @retcode = sys.sp_MSpeertopeerfwdingexec @command = @cmd,
												   @publication = @originator_publication
	end
	
	if @@error <> 0 or @retcode <> 0
		goto FAILURE

	commit transaction tr_sp_MSpeersendtopologyinfo

	return 0
FAILURE:
	rollback transaction tr_sp_MSpeersendtopologyinfo
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeersendtopologyinfo] TO [public] AS [dbo]
GO
