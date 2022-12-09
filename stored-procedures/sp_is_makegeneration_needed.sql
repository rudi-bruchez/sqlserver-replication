SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_is_makegeneration_needed]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_is_makegeneration_needed] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_is_makegeneration_needed]
	@wait [int],
	@needed [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @dt datetime
            , @dt2 datetime
            , @retcode smallint

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    -- If we need to resolve conflicts on this replica we need to call sp_MSmakegeneration
    -- Check if any row was put in generation 0 as part of conflict resolution.
    -- note that changes on join filtered rows will result on generation 0 in MSmerge_contents table.

    if @wait <= 0 or @wait >= 2147483 --if @wait is -1 (default value) or longer than the biggest value @waitinmilliseconds can hold, reset to 500 milliseconds.
    begin
        select @wait  = 1
    end

    if exists( select * from dbo.MSmerge_contents with (NOLOCK) where generation  = 0)
    begin
        select @needed = 1
        return
    end

    if exists( select * from dbo.MSmerge_tombstone with (NOLOCK) where generation  = 0)
    begin
        select @needed = 1
        return
    end

    --obtain the last time MakeGeneration is called from sysmergesubscriptions
    -- if the last_makegeneration_datetime is all NULL, it means MakeGeneration has never happened.
    select @dt2 = max(last_makegeneration_datetime) from dbo.sysmergesubscriptions
    where db_name = db_name()
           and UPPER(subscriber_server) collate database_default = UPPER(@@servername) collate database_default     

    if @dt2 is null
    begin
        select @needed = 1
        return
    end   
    
    set @dt = getdate()

    if datediff(dd, @dt2, @dt) = 0
    begin
        if @wait > datediff(ss, @dt2, @dt) and 0 < datediff(ss, @dt2, @dt)
        begin
            select @needed = 0
            return 
        end
    end

    select @needed = 1
    return
GO
GRANT EXECUTE ON [sys].[sp_is_makegeneration_needed] TO [public] AS [dbo]
GO
