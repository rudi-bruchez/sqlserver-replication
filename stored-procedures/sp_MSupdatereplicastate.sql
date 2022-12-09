SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdatereplicastate]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdatereplicastate] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdatereplicastate]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@replicastate [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
/*
        ** Check to see if current publication has permission
        */
        if ({ fn ISPALUSER(@pubid)} <> 1)
        begin   
                RAISERROR (14126, 11, -1)
                return (1)
        end

        update dbo.sysmergesubscriptions
                set replicastate= @replicastate
                where pubid = @pubid and subid = @subid

        return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSupdatereplicastate] TO [public] AS [dbo]
GO
