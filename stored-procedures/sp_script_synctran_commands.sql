SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_script_synctran_commands]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_script_synctran_commands] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_script_synctran_commands]
	@publication [sysname],
	@article [sysname],
	@trig_only [bit],
	@usesqlclr [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    --
    -- security check
    --
    if @trig_only = 0
    begin
        exec @retcode = sys.sp_MSreplcheck_publish
        if @@error <> 0 or @retcode <> 0
        begin
            return (1)
        end
    end
    else
    begin
        exec @retcode = sp_MSreplcheck_pull
            @publication = @publication,
            @raise_fatal_error = 0
        if @@error <> 0 or @retcode <> 0
        begin
            return (1)
        end
    end
    --
    -- Generate the scripts by calling internal SP
    --
    exec @retcode = sys.sp_MSget_synctran_commands 
        @publication = @publication,
        @article = @article,
        @command_only = 1,
        @trig_only = @trig_only,
        @usesqlclr = @usesqlclr
    if @retcode <> 0 or @@error <> 0
        return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_script_synctran_commands] TO [public] AS [dbo]
GO
