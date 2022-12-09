SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_tracer_token]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_tracer_token] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_tracer_token]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@tracer_id [int] OUTPUT,
	@subscribers_found [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode 				int,
			@publication_id			int,
			@SNAPSHOT_PUB			int

	--	
	-- security check
	-- only sysadmin can execute this
	--
	if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
	begin
		raiserror(21089, 16, -1)
		return (1)
	end
	
	select @retcode 				= 0,
			@publication_id			= NULL,
			@tracer_id				= NULL,
			@SNAPSHOT_PUB			= 1,
			@subscribers_found		= 0
			
	-- retrieve the publication id and ensure no snapshot pub is selected
 	select @publication_id = msp.publication_id
		from dbo.MSpublications msp
			join MSreplservers ss
				on msp.publisher_id = ss.srvid
		where UPPER(ss.srvname) = UPPER(@publisher)
			and msp.publisher_db = @publisher_db
			and msp.publication = @publication
			and msp.publication_type <> @SNAPSHOT_PUB

	if @publication_id is NULL
	begin 
		-- Publication 'publication' does not exist.
		raiserror(21200, 16, -1, @publication)
		return 1
	end

	-- check if there are any active distribution agents for.
	if not exists(select * 
					from sys.fn_activedistributionagentids(@publication_id))
	begin
		return 0
	end

	-- now we know that we have subscribers
	select @subscribers_found = 1

	begin transaction tr_sp_MSadd_tracer_token
	save transaction tr_sp_MSadd_tracer_token
	
	-- now perform an insert for the tracer token
	insert into MStracer_tokens
		(
			publication_id,
			publisher_commit
		) values 
		(
			@publication_id,
			getdate()
		)
	if @@error <> 0
		goto Err_Handler

	-- set the output tracer_id value
	select @tracer_id = scope_identity()
	
	commit transaction tr_sp_MSadd_tracer_token
	
	return 0

Err_Handler:
	rollback transaction tr_sp_MSadd_tracer_token
	commit transaction 
 
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_tracer_token] TO [public] AS [dbo]
GO
