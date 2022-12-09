SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetreplicastate]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetreplicastate] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetreplicastate]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@replicastate [uniqueidentifier] OUTPUT
WITH EXECUTE AS CALLER
AS
if ({ fn ISPALUSER(@pubid) } <> 1)
        begin   
                RAISERROR (14126, 11, -1)
                return (1)
        end
        
        select @replicastate = replicastate from dbo.sysmergesubscriptions
            where pubid = @pubid and subid = @subid
            
        return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetreplicastate] TO [public] AS [dbo]
GO
