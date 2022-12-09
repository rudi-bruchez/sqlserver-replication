SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_check_publication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_check_publication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_check_publication_access]
	@publication [sysname],
	@given_login [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	declare @retcode int

	set nocount on

	exec @retcode = sys.sp_MSreplcheck_pull 
						@publication = @publication,
						@given_login = @given_login,
						@publisher   = @publisher

	if @retcode <> 0 or @@error <> 0
	BEGIN
		return (1)
	END

	return 0
END
GO
GRANT EXECUTE ON [sys].[sp_check_publication_access] TO [public] AS [dbo]
GO
