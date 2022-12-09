SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpeerdbinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpeerdbinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpeerdbinfo]
	@is_p2p [bit] OUTPUT,
	@current_version [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
	
	declare @OPT_ENABLED_FOR_P2P int
	
	select @OPT_ENABLED_FOR_P2P = 0x1

	-- Security Check
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return 1
	end
	
	-- only retrieve the data if the database is published. return 
	-- error since this should not be called on non-published db
	if sys.fn_MSrepl_istranpublished(db_name(),0) != 1
    begin
		select @is_p2p = 0,
				@current_version = 0

		return 1
    end

	-- check if any publication is enabled for P2P
    if exists (select *
				from syspublications 
				where (options & @OPT_ENABLED_FOR_P2P) = @OPT_ENABLED_FOR_P2P)
	begin
		select @is_p2p = 1

		exec @retcode = sys.sp_MSgetdbversion @current_version = @current_version output
		if @@error <> 0 or @retcode <> 0
			return 1
	end
	else
	begin
		select @is_p2p = 0,
			@current_version = 0
	end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSpeerdbinfo] TO [public] AS [dbo]
GO
