SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdaterecgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdaterecgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdaterecgen]
	@altrepid [uniqueidentifier],
	@altrecguid [uniqueidentifier],
	@altrecgen [bigint]
WITH EXECUTE AS CALLER
AS
-- Security check
        declare @retcode int
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
        if (@retcode <> 0) or (@@error <> 0)
                return 1

        update dbo.sysmergesubscriptions
                set recguid = @altrecguid, recgen = @altrecgen,
                    last_local_recgen = case when recguid = @altrecguid or recguid is null or recguid = '00000000-0000-0000-0000-000000000000' then last_local_recgen else NULL end,
                    last_local_recguid = case when recguid = @altrecguid or recguid is null or recguid = '00000000-0000-0000-0000-000000000000' then last_local_recguid else recguid end
                where subid = @altrepid and 
                          (recgen < @altrecgen or recgen is null)

        return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSupdaterecgen] TO [public] AS [dbo]
GO
