SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorhelppublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorhelppublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorhelppublisher]
	@publisher [sysname],
	@refreshpolicy [tinyint]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@distdb sysname
				,@cmd nvarchar(4000)
                ,@orig_publisher sysname
	
    set @orig_publisher = NULL

	--
	-- security check.
	-- User must be member of 'replmonitor' role in some distribution database at this distributor.
	--
	exec @retcode = sys.sp_MSrepl_DistributorReplMonitorAccess
	if @retcode != 0 or @@error != 0
		return (1)
	--
	-- create temp table for results
	--
	create table #tmp_replication_publisherdata  
	(
		publisher sysname
		,distribution_db sysname
		,status int
		,warning int	-- OR among all subscriptions 
		,publicationcount int
		,returnstamp nvarchar(20) null
	)
	
	if @@error != 0
	begin
		raiserror(20507, 16, 1, '#tmp_replication_publisherdata', 'tempdb')
		return 1
	end
	--
	-- if publisher is not specified then enumerate through each 
	-- distribution database and collect the information
	-- if publisher is specified then execute in the specific dist db
	--
	if (@publisher is null)
	begin
		--
		-- publisher was not specified
		-- ennumerate the distribution databases
		--
		declare #hcdistdb cursor local fast_forward for
			select name from msdb..MSdistributiondbs
		open #hcdistdb
		fetch next from #hcdistdb into @distdb
		while (@@fetch_status != -1)
		begin
			--
			-- get data from the current distribution db
			--
			select @cmd = quotename(@distdb) + '.sys.sp_replmonitorhelppublisherhelper'
			exec @retcode = @cmd @publisher = @publisher, @refreshpolicy = @refreshpolicy
			if @@error != 0 or @retcode != 0
				return 1
			--
			-- get next distribution db
			--
			fetch next from #hcdistdb into @distdb
		end -- while (@@fetch_status != -1)
		close #hcdistdb
		deallocate #hcdistdb
	end
	else
	begin
		--
		-- publisher was specified
		-- validate and get the distribution database
		--
		-- Get publisher without port number
		exec sys.sp_MSget_server_portinfo 
			@name = @publisher, 
			@srvname = @publisher OUTPUT

		select @distdb = distribution_db 
		from msdb..MSdistpublishers 
		where upper(name) = upper(@publisher)
		if (@distdb is null)
		begin
            -- If we are here then either we have incorrect @publisher or it could be an AG listener for publisher
            -- To find if its an AG listener for publisher, we need to find the distribution db that has this listener. Note - we can have more than 1 distribution DB
            declare #hcdistdb cursor local fast_forward for
            select name from msdb..MSdistributiondbs
            open #hcdistdb
            fetch next from #hcdistdb into @distdb
            while (@@fetch_status != -1)
            begin
                --
                -- get original publisher from the current distribution db
                --
                select @cmd = quotename(@distdb) + '.sys.sp_replmonitorgetoriginalpublisher'
                exec @cmd @publisher, @orig_publisher OUTPUT
                if @@error != 0
                    goto UNDO
                if @orig_publisher is NOT NULL -- we found the match
                begin 
                    break
                end 
                --
                -- get next distribution db
                --
                fetch next from #hcdistdb into @distdb
            end -- while (@@fetch_status != -1)
            close #hcdistdb
            deallocate #hcdistdb

            -- if @orig_publisher is not null, then it is the original publisher for AG listener

            if @orig_publisher is NOT NULL 
            BEGIN
                set @publisher = @orig_publisher  -- We found the match and from now on we should use @orig_publisher as publisher
                select @distdb = distribution_db 
                from msdb..MSdistpublishers 
                where upper(name) = upper(@publisher)
            END
            else
            BEGIN
                if (@orig_publisher is NULL) or (@distdb is null)
                BEGIN
					raiserror (25002, 16, -1)
					return (1)
                end
            END
		end
		--
		-- get data
		--
		select @cmd = quotename(@distdb) + '.sys.sp_replmonitorhelppublisherhelper'
		exec @retcode = @cmd @publisher = @publisher, @refreshpolicy = @refreshpolicy
		if @@error != 0 or @retcode != 0
			return 1
	end
	--
	-- return the resultset
	--
	select publisher
		,distribution_db
		,status
		,warning
		,publicationcount
		,returnstamp
	from #tmp_replication_publisherdata
	--
	-- all done
	--
	return 0

UNDO:
    close #hcdistdb
    deallocate #hcdistdb
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorhelppublisher] TO [public] AS [dbo]
GO
