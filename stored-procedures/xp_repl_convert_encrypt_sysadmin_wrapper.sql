SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[xp_repl_convert_encrypt_sysadmin_wrapper]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[xp_repl_convert_encrypt_sysadmin_wrapper] AS' 
END
GO
ALTER PROCEDURE [sys].[xp_repl_convert_encrypt_sysadmin_wrapper]
	@password [nvarchar](524) OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    /*
    ** Security Check: require sysadmin
    */
    if (isnull(is_srvrolemember('sysadmin'),0) = 0)
    begin
        raiserror(21089,16,-1) 
        return (1)
    end

	-- if we have sphinx/shiloh encryption go ahead and convert
	if sys.fn_replencryptversion(@password) in (1, 2, 3)
	begin
	    exec @retcode = sys.xp_repl_convert_encrypt @password output
	    return @retcode
	end

    return 0
end
GO
GRANT EXECUTE ON [sys].[xp_repl_convert_encrypt_sysadmin_wrapper] TO [public] AS [dbo]
GO
