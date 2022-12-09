SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetlastupdatedtime]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetlastupdatedtime] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetlastupdatedtime]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscription_type [int],
	@publication_type [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    select @retcode = 0

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe    
    if @retcode<>0 or @@error<>0
        return 1

    if @publication_type in (0,1)
    begin
        exec @retcode = sys.sp_MSgettranlastupdatedtime @publisher,
                                                        @publisher_db,
                                                        @publication,
                                                        @subscription_type
    end
    else
    begin
        exec @retcode = sys.sp_MSgetmergelastupdatedtime @publisher,
                                                         @publisher_db,
                                                         @publication,
                                                         @subscription_type
    end
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetlastupdatedtime] TO [public] AS [dbo]
GO
