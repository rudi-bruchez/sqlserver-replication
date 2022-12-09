SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_scriptinsproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_scriptinsproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_scriptinsproc]
	@artid [int],
	@publishertype [tinyint],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- call core function
    --
    exec @retcode = sys.sp_scriptinsproccore 
                @artid = @artid
                ,@format = 1
                ,@mode = 1          -- regular scripting mode
                ,@publishertype = @publishertype
                ,@publisher = @publisher
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_scriptinsproc] TO [public] AS [dbo]
GO
