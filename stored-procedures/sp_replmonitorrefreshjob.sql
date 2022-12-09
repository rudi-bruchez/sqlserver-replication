SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorrefreshjob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorrefreshjob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorrefreshjob]
	@iterations [tinyint],
	@profile [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@distribution_db sysname
				,@loopcounter tinyint
				,@prechecksum int
				,@postchecksum int
				,@lastcomputetime int
				,@delaytime int 
				,@strdelaytime sysname
				,@datebuf datetime
				,@refreshpolicy tinyint

	--
	-- initialize
	--
	select @distribution_db = db_name()
				,@loopcounter = 0
				,@prechecksum = 0
				,@postchecksum = 0
				,@lastcomputetime = 0
				,@refreshpolicy = 1
	--
	-- security check
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security: Has to be executed from distribution database
	--
	if sys.fn_MSrepl_isdistdb (@distribution_db) != 1
	begin
		raiserror (21482, 16, -1, 'sp_replmonitorrefreshjob', 'distribution')
		return 1
	end
	--
	-- validate @iterations
	--
	if (@iterations < 0)
	begin
		raiserror(20587, 16, -1, '@iterations', 'sp_replmonitorrefreshjob')
		return (1)
	end
	--
	-- We are going through the main loop to do refresh
	--
	while (1=1)
	begin
		--
		-- get the checksum value before refresh
		--
		select @prechecksum = checksum(time_stamp)
			from dbo.MSreplication_monitordata
		
		--
		-- refresh the cache
		--
		exec @retcode = sys.sp_replmonitorrefreshdata @refreshpolicy = @refreshpolicy, @profile = @profile
		if @retcode != 0 or @@error != 0
			return 1
		--
		-- check if we need to break out of loop
		--
		if (@iterations > 0)
		begin
			select @loopcounter = @loopcounter + 1 
			if (@profile = 1)
				raiserror('Completed %d iteration(s)', 10, 1, @loopcounter)
			if (@iterations = @loopcounter)
				break
		end
		--
		-- we need to wait for next cycle
		-- get the checksum value after refresh
		--
		select @postchecksum = checksum(time_stamp)
					,@lastcomputetime = isnull(computetime, 0)
			from dbo.MSreplication_monitordata
	   
		--
		-- compute how much to wait in seconds
		--
		select @delaytime = case 
			-- no changes were there in cache
			when (@prechecksum = @postchecksum) then case when (30 > @lastcomputetime) then 30 else @lastcomputetime end
			-- changes were there in cache
			else case when (4 > @lastcomputetime) then 4 else @lastcomputetime end 
			end
		--
		-- convert the delaytime to usable format
		--
		select @datebuf = dateadd(ss, @delaytime, 0x0)
		select @strdelaytime = cast(datepart(hh, @datebuf) as nvarchar(4)) + N':'
					+ cast(datepart(mi, @datebuf) as nvarchar(4)) + N':'
					+ cast(datepart(ss, @datebuf) as nvarchar(6)) 
		--
		-- wait for given delay
		--
		if (@profile = 1)
			raiserror('Waitfor delay %s', 10, 1, @strdelaytime)
		waitfor delay @strdelaytime
	end -- while (1=1)
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorrefreshjob] TO [public] AS [dbo]
GO
