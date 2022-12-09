SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helparticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helparticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helparticle]
	@publication [sysname],
	@article [sysname],
	@returnfilter [bit],
	@publisher [sysname],
	@found [int] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
    DECLARE @cmd nvarchar(4000)
	DECLARE @retcode int
	DECLARE @publisher_type sysname

    select @retcode = 0

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher			= @publisher,
													@publisher_type		= @publisher_type OUTPUT,
													@rpcheader			= @cmd OUTPUT,
													@skipSecurityCheck	= 1
													
    IF @retcode <> 0
        RETURN (@retcode)

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT

	IF @publisher_type <> N'MSSQLSERVER'
	BEGIN
		select @cmd = @cmd + N'sys.sp_IHhelparticle'

		EXEC @retcode = @cmd
						@publication,
						@article,
						@returnfilter,
						@publisher,
						@publisher_type,
						@found OUTPUT
	END
	ELSE
	BEGIN
		select @cmd = @cmd + N'sys.sp_MSrepl_helparticle'

		EXEC @retcode = @cmd
				@publication,
				@article,
				@returnfilter,
				@publisher,
				@found OUTPUT
	END
	
    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helparticle] TO [public] AS [dbo]
GO
