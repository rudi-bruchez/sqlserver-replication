SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replrethrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replrethrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replrethrow]
WITH EXECUTE AS CALLER
AS
IF ERROR_NUMBER() IS NULL
        RETURN;

    DECLARE 
        @ErrorMessage    NVARCHAR(4000) = N'Error %d, Level %d, State %d, Procedure %s, Line %d, ' 
					+ 'Message: '+ ERROR_MESSAGE(),
        @ErrorNumber     INT = ERROR_NUMBER(),
        @ErrorSeverity   INT = ERROR_SEVERITY(),
        @ErrorState      INT = ERROR_STATE(),
        @ErrorLine       INT = ERROR_LINE(),
        @ErrorProcedure  NVARCHAR(200) = ISNULL(ERROR_PROCEDURE(), '-');

    RAISERROR 
        (
        @ErrorMessage, 
        @ErrorSeverity, 
        1,               
        @ErrorNumber,    -- parameter: original error number.
        @ErrorSeverity,  -- parameter: original error severity.
        @ErrorState,     -- parameter: original error state.
        @ErrorProcedure, -- parameter: original error procedure name.
        @ErrorLine       -- parameter: original error line number.
        );
GO
GRANT EXECUTE ON [sys].[sp_replrethrow] TO [public] AS [dbo]
GO
