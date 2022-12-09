SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplupdateschema]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplupdateschema] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplupdateschema]
	@object_name [nvarchar](517)
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    IF @object_name IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@object_name', 'sp_MSreplupdateschema')
        RETURN (1)
    END

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
            return (1)

    exec sys.sp_replupdateschema @object_name
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplupdateschema] TO [public] AS [dbo]
GO
