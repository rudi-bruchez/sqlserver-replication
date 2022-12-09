SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_refresh_heterogeneous_publisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_refresh_heterogeneous_publisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_refresh_heterogeneous_publisher]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @cmd nvarchar(4000)
                ,@retcode int
                ,@publisher_type sysname

    exec @retcode = sys.sp_MSrepl_getpublisherinfo  @publisher        = @publisher,
                                                                        @rpcheader        = @cmd OUTPUT,
                                                                        @publisher_type    = @publisher_type OUTPUT
    
    if @retcode <> 0
        return (@retcode)

    select @publisher = UPPER(@publisher) 
            ,@cmd = @cmd + N'sys.sp_MSrepl_refresh_heterogeneous_publisher'
    
    exec @retcode = @cmd
                    @publisher,
                    @publisher_type

    return (@retcode)
end
GO
GRANT EXECUTE ON [sys].[sp_refresh_heterogeneous_publisher] TO [public] AS [dbo]
GO
