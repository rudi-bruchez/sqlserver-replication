SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreinit_failed_subscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreinit_failed_subscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreinit_failed_subscriptions]
	@failure_level [int]
WITH EXECUTE AS CALLER
AS
declare @publisher sysname
	declare @publisher_db sysname
	declare @publication sysname
	declare @article sysname
	declare @publication_type int
	declare @subscriber sysname
	declare @subscriber_db sysname
	declare @agent_type int
	declare @alert_id int
	declare @proc nvarchar(100)
	declare @message nvarchar(4000)
	declare @retcode int
	declare @found bit
	declare @return_value int
				,@current_principal sysname
	
	set nocount on

	set @found = 0          -- set if cursor returns a row
	set @return_value = 0   -- set to success

	-- Security Check: require sysadmin
	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror(21089,16,-1) 
		return (1)
	end

	-- For each publication validation failure, resync the subscription
	declare hc CURSOR LOCAL FAST_FORWARD for select publisher, publisher_db, publication, publication_type, article, subscriber, 
		subscriber_db, alert_id from 
		msdb.dbo.sysreplicationalerts where
		(@failure_level = 0 or (@failure_level = 1 and alert_error_code = 20574)) and   -- 20574 = validation failure
		status = 0
		for read only

	open hc
	fetch hc into  @publisher, @publisher_db, @publication, @publication_type, @article, @subscriber, @subscriber_db, @alert_id
	while (@@fetch_status <> -1)
	begin
		
		set @found = 1

		BEGIN TRY
			set @proc = QUOTENAME(@publisher) + '..sys.sp_MSGetCurrentPrincipal'
			exec @retcode = @proc
				@db_name = @publisher_db
				,@current_principal = @current_principal output
		END TRY
		BEGIN CATCH
			select @current_principal =  @publisher
		END CATCH

		select @publisher = isnull(@current_principal, @publisher)
		
		-- Reinit snapshot or transactional subscription (article level)
		if @publication_type = 0 or @publication_type = 1
		begin
			set @proc = QUOTENAME(@publisher) + '.' + QUOTENAME(@publisher_db) + '.dbo.sp_reinitsubscription'
			exec @retcode = @proc
				@publication = @publication,
				@article = @article,
				@subscriber = @subscriber,
				@destination_db = @subscriber_db
			-- Ignore failures, update status bit if successful
			if @retcode = 0
			begin
				-- Change status to 1 which means the alerts has been serviced
				update msdb.dbo.sysreplicationalerts set status = 1 where alert_id = @alert_id

				-- Raiserror that subscription was reinitialized
				if @failure_level = 0
					-- 'Subscriber ''%s'' subscription to article ''%s'' in publication ''%s'' has been reinitialized after a synchronization failure.'
					raiserror(20576, 10,-1, @subscriber, @article, @publication) 
				else if @failure_level  = 1
					-- 'Subscriber ''%s'' subscription to article ''%s'' in publication ''%s'' has been reinitialized after a validation failure.'
					raiserror(20572, 10,-1, @subscriber, @article, @publication) 
			end
			else -- failure
				set @return_value = 1
		end
		-- Reinit merge subscription (full publication)
		else if @publication_type = 2       
		begin
			set @proc = QUOTENAME(@publisher) + '.' + QUOTENAME(@publisher_db) + '.dbo.sp_reinitmergesubscription'
			exec @retcode = @proc
				@publication = @publication,
				@subscriber = @subscriber,
				@subscriber_db = @subscriber_db
			-- Ignore failures, update status bit if successful
			if @retcode = 0
			begin
				-- Change status to 1 which means the alerts has been serviced
				update msdb.dbo.sysreplicationalerts set status = 1 where alert_id = @alert_id

				-- Raiserror that subscription was reinitialized
				if @failure_level = 0
					-- 'Subscriber ''%s'' subscription to to article ''%s'' in publication ''%s'' has been reinitialized after a synchronization failure.'
					 raiserror(20576, 10,-1, @subscriber, @article, @publication) 
				else if @failure_level  = 1
					-- 'Subscriber ''%s'' subscription to to article ''%s'' in publication ''%s'' has been reinitialized after a validation failure.'
					raiserror(20572, 10,-1, @subscriber, @article, @publication)
			end
			else -- failure
				set @return_value = 1
		end

		fetch hc into  @publisher, @publisher_db, @publication, @publication_type, @article, @subscriber, @subscriber_db, @alert_id
	end

	close hc
	deallocate hc

	-- Return a message stating no entries where found
	if @found = 0
	begin
		-- 'No entries were found in msdb.dbo.sysreplicationalerts.'
		raiserror(20577, 10,-1) 

		-- There is most likely a problem, set failure return value
		set @return_value = 1
	end

	return @return_value 
GO
GRANT EXECUTE ON [sys].[sp_MSreinit_failed_subscriptions] TO [public] AS [dbo]
GO
