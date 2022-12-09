SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheckIsPubOfSub]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheckIsPubOfSub] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheckIsPubOfSub]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@pubOfSub [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

	if exists(select sms_a.subid from sysmergesubscriptions as sms_a 
	                where pubid in (select smp.pubid from sysmergesubscriptions as sms join sysmergepublications as smp on 
	                    sms.subscriber_server = smp.publisher and sms.db_name = smp.publisher_db where sms.subid = @pubid)
	                and sms_a.subid <> sms_a.pubid and sms_a.subid = @subid)
	begin
		select @pubOfSub = 1
	end
	else
	begin
		select @pubOfSub = 0
	end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MScheckIsPubOfSub] TO [public] AS [dbo]
GO
