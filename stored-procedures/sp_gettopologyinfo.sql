SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_gettopologyinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_gettopologyinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_gettopologyinfo]
	@request_id [int]
WITH EXECUTE AS CALLER
AS
begin

	declare @request_complete bit,
			@request_exists bit,
			@retcode		int

	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end

	-- if no request_id is specified, get the most recent completed request
	if @request_id is NULL
	begin
		select @request_id = (select top 1 id
		 					from MSpeer_topologyrequest
		 					order by sent_date desc)

		 if @@error <> 0 or @request_id is NULL
		 begin
		 	return 1
		 end
	end
	-- otherwise, make sure that the specified request exists
	else
	begin
		select @request_exists = (select case when exists(select * 
											from MSpeer_topologyrequest
											where id = @request_id
											) then 0 else 1 end)

		if @@error <>0 or @request_exists <> 0
		begin
			return 1
		end
	end

	-- check to see if the request has been completed or not
	select @request_complete = (select case when exists(select * 
								from MSpeer_topologyresponse 
								where received_date is NULL
									and request_id = @request_id
								) then 1 else 0 end)

	-- format the xml nicely
	select * from
	(
		select 1 as Tag,
				NULL as Parent,
				sent_date as [TopologyInformation!1!RequestDate],
				NULL as [Publisher!2!!xmltext],
				NULL as [Publisher!2!ReceivedDate],
				NULL as [Publisher!2!Name],
				NULL as [Publisher!2!Database],
				NULL as [Publisher!2!Version],
				NULL as [Publisher!2!OriginatorId],
				NULL as [Publisher!2!ConflictRetention]
		from MSpeer_topologyrequest
		where id = @request_id
		union all
		select 2,1,
				sent_date,
				connection_info,
				received_date,
				peer,
				peer_db,
				cast(peer_version as nvarchar), -- cast(167773193 as nvarchar),
				cast(originator_id as nvarchar), -- cast(1 as nvarchar),
				cast(peer_conflict_retention as nvarchar) -- cast(60 as nvarchar)
		from MSpeer_topologyresponse join MSpeer_topologyrequest
			on id = request_id
		where id = @request_id
	) as universal_table
	order by [TopologyInformation!1!RequestDate],[Publisher!2!ReceivedDate],[Publisher!2!Name],[Publisher!2!Database]
	for xml explicit

	if @@error <>0
	begin
		return 1
	end

	if @request_complete <> 0
	begin
		return 2
	end
	
 	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_gettopologyinfo] TO [public] AS [dbo]
GO
