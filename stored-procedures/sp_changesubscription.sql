SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changesubscription]
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@property [nvarchar](30),
	@value [nvarchar](4000),
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_changesubscription'
	
	EXEC @retcode = @cmd
					@publication 	= @publication,
				    @article 		= @article,
				    @subscriber 	= @subscriber ,
				    @destination_db	= @destination_db,
				    @property 		= @property,      
				    @value 			= @value,
				    @publisher		= @publisher,
				    @publisher_type	= @publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_changesubscription] TO [public] AS [dbo]
GO
