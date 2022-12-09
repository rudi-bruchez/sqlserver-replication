SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replpostsyncstatus]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replpostsyncstatus] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replpostsyncstatus]
	@pubid [int],
	@artid [int],
	@syncstat [int],
	@xact_seqno [binary](10) OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
	/*
	** Security Check, this proc is called by snapshot agent as DBO on publisher
	*/
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
	begin
			return(1)
	end

	exec @retcode = sys.sp_replpostsyncstatus_int @pubid, @artid, @syncstat, @xact_seqno OUTPUT
	if @@ERROR <> 0 or @retcode <> 0
	begin
			return(1)
	end
	return 0
GO
GRANT EXECUTE ON [sys].[sp_replpostsyncstatus] TO [public] AS [dbo]
GO
