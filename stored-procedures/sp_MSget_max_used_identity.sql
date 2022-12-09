SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_max_used_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_max_used_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_max_used_identity]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@max_used [numeric](38, 0) OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @retcode tinyint
	declare @publisher_id int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	-- Has to be executed from distribution database
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_MSget_max_used_identity', 'distribution')
		return 1
	end

    select @publisher_id = srvid
        from MSreplservers
        where upper(srvname) = upper(@publisher)
    if @publisher_id is NULL
    begin
        -- Publisher @publisher does not exist.
        raiserror(21618, 16, -1, @publisher)
        return 1
    end

	select top 1 @max_used = max_used from dbo.MSmerge_identity_range_allocations 
		where publisher_id = @publisher_id and 
			  publisher_db = @publisher_db and 
			  publication = @publication and 
			  article = @article
	order by time_of_allocation desc
	if @@error<>0 
		return 1

	return 0
	
GO
GRANT EXECUTE ON [sys].[sp_MSget_max_used_identity] TO [public] AS [dbo]
GO
