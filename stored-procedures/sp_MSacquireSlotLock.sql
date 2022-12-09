SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSacquireSlotLock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSacquireSlotLock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSacquireSlotLock]
	@process_name [sysname],
	@concurrent_max [int],
	@queue_timeout [int],
	@return_immediately [bit],
	@DbPrincipal [sysname]
WITH EXECUTE AS CALLER
AS
declare @entry_date     datetime
declare @slot_name      nvarchar(150)  -- OUTPUT 
-- must give back slot acquired to caller so caller can later release.
declare @basetime       datetime
declare @delaytime      datetime
declare @retcode        int
declare @i              int
declare @lock_acquired  bit

-- Security Checking 
-- sysadmin or db_owner or replication agent have access
exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
if (@retcode <> 0) or (@@error <> 0)
begin
        RAISERROR (14126, 11, -1)
       return 1
end

select @lock_acquired = 0
if @queue_timeout<0
    begin
        raiserror(21344, 16, -1, '@queue_timeout')
        return (1)      
    end
    
if @concurrent_max<=0
    begin
        raiserror(21344, 16, -1, '@concurrent_max')
        return (1)      
    end

if @DbPrincipal is NULL 
begin
    if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
        select @DbPrincipal = N'MSmerge_PAL_role'
    else
        select @DbPrincipal = N'db_owner'
end

select @entry_date=getdate()
select @delaytime = '00:00:02' 
--polling interval is defaulted to 2 seconds

SET @slot_name=NULL -- If terminate anywhere unexpectedly, dont want to give 
                    -- caller a lock they didnt really get.

-- We are at front of queue, so check if any available 'slot' is open.   
-- We do not wait at all for these locks, and hence 
-- expect either it was granted or timed out (-1).

SET @i=1

WHILE (@i <= @concurrent_max)
    BEGIN
        --the process has waited long enough. quit now and try later. 
        -- If @queue_timeout is 0, keep waiting until succeeds.
        if @queue_timeout>0 and DATEADD(second, -@queue_timeout,  getdate()) 
            > @entry_date
            begin
                select @lock_acquired = 1 -- not a peek but has waited as specified
                select @slot_name = NULL -- waited but failed to get one
                BREAK
            end

        SET @slot_name=@process_name+convert(varchar,@i)
        
        --the call is not blocking, return immediately having acquired 
        -- the lock or not
        exec @retcode=sys.sp_getapplock @Resource=@slot_name,@LockMode=N'Exclusive',
            @LockOwner='Session',@LockTimeout=0,@DbPrincipal=@DbPrincipal
        IF (@retcode <> 0 AND @retcode <> -1)
            BEGIN
                RAISERROR(21414,16,-1)
                RETURN(@retcode)
            END
    
        IF (@retcode = 0)       -- got lock for that slot - cleanup and leave.
            BEGIN
                -- Release the "Im first lock"
                exec @retcode=sys.sp_releaseapplock @process_name,@LockOwner=N'Session',@DbPrincipal=@DbPrincipal
                IF (@retcode <> 0)
                BEGIN
                    SET @slot_name=NULL
                    RAISERROR(21415, 16, -1)
                    RETURN(@retcode)
                END
                select @lock_acquired = 1
                -- We got our slot and released the Im first lock.  We're done.
                BREAK
            END
        ELSE
        IF (@retcode = -1)  -- Couldn't immediately get the lock.  
                            -- So try the next one.
            BEGIN
            SET @i=@i+1
                IF @i <= @concurrent_max
                    CONTINUE   -- restart the loop
                ELSE
                    BEGIN       -- Sleep and start over.
                    if @return_immediately=1
                        begin
                            select @lock_acquired = 0 
                            --slot name does not matter in this case
                            BREAK
                        end
                    else
                        begin
                            WAITFOR DELAY @delaytime
                            SET @i=1
                            CONTINUE   -- restart the loop
                        end
                    END
            END
        
    END
    
    --output the slot name for the purpose of releasing the lock by the caller
    --if the value if NULL, the caller does not acquire the lock
    select @lock_acquired, @slot_name
RETURN(0)
GO
GRANT EXECUTE ON [sys].[sp_MSacquireSlotLock] TO [public] AS [dbo]
GO
