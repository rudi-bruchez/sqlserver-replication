SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSstopsnapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSstopsnapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSstopsnapshot_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror (21089, 16, -1)
		return 1
	end
	
	-- database must be distribution db
	if sys.fn_MSrepl_isdistdb(db_name()) <> 1
	begin
		raiserror (21482, 16, -1, 'sp_MSstopsnapshot_agent', 'distribution')
		return 1
	end

	declare @retcode int
			,@stop tinyint
	set @stop = 1
	exec @retcode = sys.sp_MSsnapshotagentjobcontrol
		@publisher = @publisher,
		@publisher_db = @publisher_db,
		@publication = @publication,
		@action = @stop        
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSstopsnapshot_agent] TO [public] AS [dbo]
GO
