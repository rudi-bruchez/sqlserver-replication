SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSacquireHeadofQueueLock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSacquireHeadofQueueLock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSacquireHeadofQueueLock]
	@process_name [sysname],
	@queue_timeout [int],
	@no_result [bit],
	@return_immediately [bit],
	@DbPrincipal [sysname]
WITH EXECUTE AS CALLER
AS
declare @entry_date     datetime
declare @delay_time     int --in second
declare @retcode        int
declare @max_waiting    int
declare @lock_acquired  bit

-- Security Checking 
-- sysadmin or db_owner or PAL user of some publication have access
exec @retcode = sys.sp_MSrepl_PAL_rolecheck
if (@retcode <> 0) or (@@error <> 0)
begin
        RAISERROR (14126, 11, -1)
       return 1
end

if @queue_timeout<0
    begin
        raiserror(21344, 16, -1, '@queue_timeout')
        return (1)      
    end
        
if @queue_timeout> 3600*12 -- more than 12 hours is not allowed: 
                           -- make it 0 in this case.
    begin
        raiserror(21417, 16, -1) 
        return (1)
    end

if @DbPrincipal is NULL 
begin
    if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
        select @DbPrincipal = N'MSmerge_PAL_role'
    else
        select @DbPrincipal = N'db_owner'
end


--quick peek and leave
if @return_immediately=1
    begin
        --take a peek: return without wait regardless of whether the lock 
        --is successfully acquired.
        exec @retcode=sys.sp_getapplock @Resource=@process_name,
            @LockMode=N'Exclusive',@LockOwner='Session',@LockTimeout=0,
            @DbPrincipal = @DbPrincipal
        if (@retcode <> 0 AND @retcode <> -1)
            begin
                RAISERROR(21414,16,-1)
                RETURN(@retcode)
            end
        IF (@retcode = 0)       -- AppLock acquired
            select 1, 0         -- 1 means lock acquired, 0 is the time 
                                -- consumed to acquired this lock.
        else if @retcode = -1   -- AppLock is not available 
            select 0, 0         -- first 0 means lock not available, 
                                -- second column will be ignored.
        return (0)              -- OK
    end     

-- from now on, @return_immediately=0
-- if @queue_timeout=0, means waiting indefinitely
if @queue_timeout=0
    select @max_waiting = NULL
else
--otherwise convert to minisecond and pass it down.
    select @max_waiting = @queue_timeout * 1000


select @delay_time=0
select @entry_date=getdate()

-- First try to acquire EXCLUSIVE lock which signfies at front of queue.
-- i.e. I'm next.

exec @retcode=sys.sp_getapplock @process_name, @LockMode=N'Exclusive',
    @LockOwner=N'Session', @LockTimeout=@max_waiting, @DbPrincipal=@DbPrincipal

-- We shouldn't return from above until we have it 
-- RC should be either 0 (got immediately) or 1 (waited and got it eventually) or -1 (timed out); Exit on anything else.
-- We need value -1 because @LockTimeout value is no longer NULL, 
-- meaning waiting indefinitely. It is possible 
-- that we waited for a given length of time and timed out
IF (@retcode <> 0 and @retcode <> 1) and @retcode<>-1
    BEGIN
        RAISERROR(21413, 16, -1)
        RETURN(@retcode)
    END
    
-- Im-first lock is to be released after successfully 
-- obtained a slot lock later.
select @delay_time=datediff(ss, @entry_date, getdate())
if @retcode=-1
    select @lock_acquired=0
else
    select @lock_acquired=1

if @no_result = 0
begin
    select @lock_acquired, @delay_time
end

RETURN(0)
GO
GRANT EXECUTE ON [sys].[sp_MSacquireHeadofQueueLock] TO [public] AS [dbo]
GO
