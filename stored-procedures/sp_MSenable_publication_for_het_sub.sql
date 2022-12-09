SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenable_publication_for_het_sub]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenable_publication_for_het_sub] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenable_publication_for_het_sub]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@sync_method [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on
	
 	declare @publisher_id smallint,
 			@OPT_ENABLED_FOR_HET_SUB tinyint,
 			@retcode int
 			
 	set @OPT_ENABLED_FOR_HET_SUB = 0x4		

	-- security check
	-- only db_owner can execute this
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	-- security check
	-- Has to be executed from distribution database
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSenable_publication_for_het_sub', 'distribution')
		return (1)
	end
	
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	begin tran
	
	UPDATE dbo.MSpublications
	SET
			options = @OPT_ENABLED_FOR_HET_SUB,
			-- Unsupported options are explicitly set to 0 or null, as appropriate
			allow_pull = 0,
			allow_queued_tran = 0,
			allow_subscription_copy = 0,
			sync_method = @sync_method
	WHERE   publisher_id = @publisher_id AND
			publisher_db = @publisher_db AND
			publication = @publication
			
	IF @@ERROR <> 0 
			goto UNDO

	COMMIT TRAN

	RETURN(0)

UNDO:
	IF @@TRANCOUNT = 1
		ROLLBACK TRAN
	ELSE
		COMMIT TRAN   
	RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSenable_publication_for_het_sub] TO [public] AS [dbo]
GO
