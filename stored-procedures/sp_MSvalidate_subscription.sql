SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSvalidate_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSvalidate_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSvalidate_subscription]
	@subscriber [sysname],
	@subscriber_db [sysname],
	@artid [int]
WITH EXECUTE AS CALLER
AS
begin
    if not exists (select * 
        from syssubscriptions as sub
            where sub.srvname = UPPER(@subscriber) 
			and (sub.srvname is not null and len(sub.srvname)> 0)
            and sub.artid = @artid 
            and sub.dest_db = @subscriber_db)
    begin
        --  The subscription has been dropped from the publisher. Please run sp_subscription_cleanup to cleanup the triggers.
        exec sys.sp_MSreplraiserror 21161
        return -1
    end
end
GO
GRANT EXECUTE ON [sys].[sp_MSvalidate_subscription] TO [public] AS [dbo]
GO
