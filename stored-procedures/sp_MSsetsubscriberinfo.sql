SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetsubscriberinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetsubscriberinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetsubscriberinfo]
	@pubid [uniqueidentifier],
	@expr [nvarchar](500)
WITH EXECUTE AS CALLER
AS
-- Security Checking 
    -- PAL users have access
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
            RAISERROR (21723, 16, -1, 'sp_MSsetsubscriberinfo')
            return 1
        end
        else
        begin
            RAISERROR (14126, 11, -1)
            return 1
        end
    end
    
    update dbo.sysmergepublications set validate_subscriber_info = @expr where pubid = @pubid
GO
GRANT EXECUTE ON [sys].[sp_MSsetsubscriberinfo] TO [public] AS [dbo]
GO
