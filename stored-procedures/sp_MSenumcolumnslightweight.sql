SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumcolumnslightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumcolumnslightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumcolumnslightweight]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode	int
    declare @procname	sysname
	declare @postfix	nchar(32)

	exec @retcode= sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0 return (1)


	select @postfix= procname_postfix
		from dbo.sysmergearticles 
		where artid = @artid and pubid = @pubid
	
	set @procname= quotename('MSmerge_lws_sp_multi_' + @postfix)

	exec @retcode= @procname @action=6
	if @@error<>0 or @retcode<>0 return (1)

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSenumcolumnslightweight] TO [public] AS [dbo]
GO
