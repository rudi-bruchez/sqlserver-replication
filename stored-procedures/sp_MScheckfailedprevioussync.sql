SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheckfailedprevioussync]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheckfailedprevioussync] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheckfailedprevioussync]
	@pubid [uniqueidentifier],
	@last_sync_failed [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0) or (@@error <> 0)
        return 1

	if exists(select * from dbo.MSmerge_genhistory mgh JOIN dbo.sysmergearticles sma
				ON mgh.art_nick = sma.nickname
				where mgh.genstatus = 4 and 
					(sma.pubid = @pubid or mgh.art_nick = 0))
	begin
		select @last_sync_failed = 1
	end
	else
	begin
		select @last_sync_failed = 0
	end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MScheckfailedprevioussync] TO [public] AS [dbo]
GO
