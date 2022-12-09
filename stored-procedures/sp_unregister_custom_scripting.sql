SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_unregister_custom_scripting]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_unregister_custom_scripting] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_unregister_custom_scripting]
	@type [varchar](16),
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	exec @retcode = sys.sp_register_custom_scripting @type = @type, @value = NULL, @publication = @publication, @article = @article
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_unregister_custom_scripting] TO [public] AS [dbo]
GO
