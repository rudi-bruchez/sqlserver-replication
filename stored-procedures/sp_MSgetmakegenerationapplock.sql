SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmakegenerationapplock]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmakegenerationapplock] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmakegenerationapplock]
	@head_of_queue [int] OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @retcode smallint
    declare @lock_resource nvarchar(255)
    declare @DbPrincipal sysname

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1
    
      select @retcode = 0
    select @head_of_queue = 0
    
    select @lock_resource = N'MSinternal_makegeneration_inprogress' + 
                convert(nvarchar(11), db_id())
    if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
        select @DbPrincipal = N'MSmerge_PAL_role'
    else
        select @DbPrincipal = N'db_owner'
    
	-- If the current session has not acquired the make generation inprogress applock, do it.
	-- Otherwise skip acquring the applock to avoid request_reference_count being increased.
	if not exists (select * from sys.dm_tran_locks where request_session_id = @@SPID and resource_description like N'%MSinternal_makegeneration_inprog%' and resource_database_id = db_id())
	begin
		-- If someone else is making generations / has just made one, exit so
		-- that we won't deadlock
		exec @retcode = sp_getapplock @Resource = @lock_resource,
									  @LockMode = N'Exclusive',
									  @LockOwner = N'Session',
									  @LockTimeout = 0, -- do not wait at all. 
									  @DbPrincipal = @DbPrincipal

		if @@error <> 0 or @retcode < 0
		begin
			-- If the previous applock request timed out, then try again, this time using the default timeout.
			-- Note that even though the -1 lock timeout means indefinite timeout, the query timeout set on the 
			-- session overrides the lock timeout. So it's okay even if the default @@lock_timeout is -1.
			if (@retcode = -1)
			begin
				exec @retcode = sp_getapplock @Resource = @lock_resource,
							@LockMode = N'Exclusive',
							@LockOwner = N'Session',
							@DbPrincipal = @DbPrincipal

				-- If we succeeded to get the lock, set @lock_acquired to 1 so that the exit code releases the lock.
				if (@retcode >= 0)
				begin
					goto EXIT_PROC
				end
			end
		end
		else
		begin
			select @head_of_queue = 1
		end
    end
    else
    begin
		-- If the current session has already acquired the lock, set retcode and return 
		-- This could happen if the session's previous makegen operation acquired the applock but encountered deadlock during execution 
		select @retcode = 1
        select @head_of_queue = 1
    end

EXIT_PROC:
    return @retcode

GO
GRANT EXECUTE ON [sys].[sp_MSgetmakegenerationapplock] TO [public] AS [dbo]
GO
