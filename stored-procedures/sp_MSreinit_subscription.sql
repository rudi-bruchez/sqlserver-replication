SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreinit_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreinit_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreinit_subscription]
	@publisher_name [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber_name [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @proc nvarchar(2048)
	declare @retcode int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

    if @publisher_name IS NULL or NOT EXISTS (select * from MSreplservers as ss, dbo.MSpublications as msp
        where lower(ss.srvname) = lower(@publisher_name) and msp.publisher_id = ss.srvid)
    begin
        return (1)
    end

	if @publisher_db IS NULL
		select @publisher_db = ''

	select @proc = quotename(ltrim(rtrim(@publisher_name))) + '.' + quotename(@publisher_db) + '.dbo.sp_reinitsubscription '
	exec @retcode = @proc @publication, 'all', @subscriber_name, @subscriber_db

	return (@retcode)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreinit_subscription] TO [public] AS [dbo]
GO
