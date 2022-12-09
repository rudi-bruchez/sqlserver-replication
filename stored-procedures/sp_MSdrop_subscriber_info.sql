SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_subscriber_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_subscriber_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_subscriber_info]
	@publisher [sysname],
	@subscriber [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @srvid smallint
	declare @publisher_id smallint
	declare @publisher_db sysname
  
	-- Security Check
	IF IS_SRVROLEMEMBER ('sysadmin') != 1
	BEGIN
		-- "You do not have sufficient permission to run this command."
		RAISERROR(14260, 16, -1)
		RETURN 1
	END
	
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSdrop_subscriber_info', 'distribution')
		return (1)
	end

	if exists (select * from MSsubscriber_info where
		UPPER(subscriber) = UPPER(@subscriber))
	begin

        select @srvid = srvid from MSreplservers where lower(srvname) = lower(@subscriber)

		-- For SQL server publishers, drop the existing subscriptions.
		-- This has to be done for 65 upgrade.
		-- For third party, check for error.
		if exists (select * from msdb..MSdistpublishers where 
			lower(name) = lower(@publisher) and
			thirdparty_flag = 0)
		begin
			-- This is needed for 6.5 upgrade.
			-- Remove subscription entries for this publisher and subscriber pair
			-- Get dist publisher ID
			exec sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
			delete dbo.MSsubscriptions where subscriber_id = @srvid and 
				publisher_id = @publisher_id
		end
		else
		begin
			if exists (select * from dbo.MSsubscriptions where subscriber_id = @srvid)
			begin
				raiserror(20100, 16, -1, @subscriber)
				return (1)
			end
		end

		delete MSsubscriber_info where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			return 1
		delete MSsubscriber_schedule where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			return 1
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_subscriber_info] TO [public] AS [dbo]
GO
