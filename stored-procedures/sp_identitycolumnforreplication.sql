SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_identitycolumnforreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_identitycolumnforreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_identitycolumnforreplication]
	@object_id [int],
	@value [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @identity_column sysname

	IF IS_SRVROLEMEMBER('sysadmin') = 0
		AND IS_MEMBER('db_owner') = 0
	BEGIN
		RAISERROR(21050, 14, -1)
		RETURN 1
	END

	SELECT @identity_column = NULL

	SELECT @identity_column = name 
		FROM sys.columns
		WHERE object_id = @object_id
			AND COLUMNPROPERTY(object_id, name, 'IsIdentity') = 1
	IF @identity_column IS NOT NULL
	BEGIN
		EXEC %%ColumnEx(ObjectID = @object_id, Name = @identity_column).SetIdentityNotForRepl(Value = @value)
		IF @@ERROR <> 0 
			RETURN 1
	END

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_identitycolumnforreplication] TO [public] AS [dbo]
GO
