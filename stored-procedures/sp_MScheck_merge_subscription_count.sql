SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_merge_subscription_count]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_merge_subscription_count] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_merge_subscription_count]
	@publisher [sysname],
	@publisher_engine_edition [int],
	@about_to_insert_new_subscription [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
	
	-- Security Check: require sysadmin/dbo of dist 
	IF IS_MEMBER('db_owner') != 1
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MScheck_merge_subscription_count', 'distribution')
		RETURN 1
	END

	exec @retcode = sys.sp_MScheck_subscription_count_internal @mode=1 
									,@publisher = @publisher
									,@publisher_engine_edition = @publisher_engine_edition
									,@about_to_insert_new_subscription = @about_to_insert_new_subscription
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_merge_subscription_count] TO [public] AS [dbo]
GO
