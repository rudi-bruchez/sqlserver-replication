SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_subscription_dts_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_subscription_dts_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_subscription_dts_info]
	@job_id [varbinary](16),
	@dts_package_name [sysname],
	@dts_package_password [nvarchar](524),
	@dts_package_location [int],
	@change_password [bit]
WITH EXECUTE AS CALLER
AS
begin
	/*
	** Declarations.
	*/
	declare @subscriber sysname
	declare @publisher sysname
	declare @subscriber_id smallint
	declare @publisher_id smallint

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSchange_subscription_dts_info', 'distribution')
		return (1)
	end
	/*
	** Initializations.
	*/
	SET NOCOUNT ON
	
	select @subscriber_id = subscriber_id, @publisher_id = publisher_id 
		from MSdistribution_agents where 
		job_id = @job_id
	
	select @subscriber = srvname from MSreplservers where srvid = @subscriber_id
	select @publisher = srvname from MSreplservers where srvid = @publisher_id

	declare @oledb_subscriber tinyint
	select @oledb_subscriber = 3
	
	-- Only SQL Server and OLEDB subscriber support dts
	if not exists (select * from MSsubscriber_info where 
		UPPER(publisher) = UPPER(@publisher) and 
		UPPER(subscriber) = UPPER(@subscriber) and
		(type = 0 or type = @oledb_subscriber))
	begin
		raiserror(21170, 16, -1)
		return 1
	end
	
	
	update MSdistribution_agents set
		dts_package_name = case 
			when @dts_package_name is null then dts_package_name
			when @dts_package_name = N'' then null
			else @dts_package_name
			end, 
		dts_package_password = case @change_password
			when 0 then dts_package_password
			else @dts_package_password
			end, 
		dts_package_location = case
			when @dts_package_location is null then dts_package_location
			else @dts_package_location
			end
		where
			job_id = @job_id

	RETURN (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_subscription_dts_info] TO [public] AS [dbo]
GO
