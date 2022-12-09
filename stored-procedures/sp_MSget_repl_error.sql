SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_repl_error]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_repl_error] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_repl_error]
	@id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	select  source_type_id, source_name, error_code, error_text, 
			sys.fn_replformatdatetime(time),
			error_type_id, 
			'has_xact_seqno' = case when xact_seqno is null or xact_seqno = 0x0
				then convert(bit, 0) else convert(bit, 1) end,
			xact_seqno, command_id
		from dbo.MSrepl_errors
		where
			id = @id and
			-- rows with error_type_id are placeholders
			error_type_id IS NOT NULL
		order by time ASC
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_repl_error] TO [public] AS [dbo]
GO
