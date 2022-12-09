SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplcheckoffloadserver]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplcheckoffloadserver] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplcheckoffloadserver]
	@offloadserver [sysname]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON
	
	RAISERROR(21023, 16, -1, 'sp_MSreplcheckoffloadserver')

	RETURN (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplcheckoffloadserver] TO [public] AS [dbo]
GO
