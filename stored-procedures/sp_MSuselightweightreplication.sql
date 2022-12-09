SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSuselightweightreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSuselightweightreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSuselightweightreplication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@lightweight [int] OUTPUT
WITH EXECUTE AS CALLER
AS
/*
	** Check for dbo permission
	*/
	declare @retcode int
	exec @retcode=sys.sp_MSreplcheck_subscribe
	if @retcode<>0 or @@ERROR<>0 
		return (1)
		
	set @lightweight= sys.fn_MSuselightweightreplication (@publisher, @publisher_db, @publication, null, null, null, null)
GO
GRANT EXECUTE ON [sys].[sp_MSuselightweightreplication] TO [public] AS [dbo]
GO
