SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replsetoriginator]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replsetoriginator] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replsetoriginator]
	@originator_srv [sysname],
	@originator_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int
	/*
	   ** Security Check, if @publication is supplied, check for PAL, otherwise DBO
	   */
	if @publication  is not null
	begin
		exec @retcode = sys.sp_MSreplcheck_pull @publication = @publication
		if @@error <> 0 or @retcode <> 0
		begin
			return (1)
		end
	end
	else
	begin
		   exec @retcode = sys.sp_MSreplcheck_subscribe
		   if @@ERROR <> 0 or @retcode <> 0
		begin
			return(1)
		end
	end
	
	exec @retcode = sys.sp_replsetoriginator_internal @originator_srv, @originator_db
	if @@ERROR <> 0 or @retcode <> 0
	begin
			return(1)
	end

	return 0
GO
GRANT EXECUTE ON [sys].[sp_replsetoriginator] TO [public] AS [dbo]
GO
