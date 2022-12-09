SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplraiserror]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplraiserror] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplraiserror]
	@errorid [int],
	@param1 [sysname],
	@param2 [sysname],
	@param3 [int]
WITH EXECUTE AS CALLER
AS
if @errorid = 20508 raiserror (20508, 11, 1)
    else if @errorid = 20509 raiserror (20509, 16, 1)
    else if @errorid = 20510 raiserror (20510, 16, 1)
    else if @errorid = 20511 raiserror (20511, 16, 1)
    else if @errorid = 20512 raiserror (20512, 16, 1)
    else if @errorid = 20515 raiserror (20515, 16, 1)
    else if @errorid = 20516 raiserror (20516, 16, 1)
    else if @errorid = 20504 raiserror (20504, 16, 1)
    else if @errorid = 20518 raiserror (20518, 16, 1)
    else if @errorid = 20519 raiserror (20519, 16, 1)
    else if @errorid = 20520 raiserror (20520, 16, 1)
    else if @errorid = 21034 raiserror (21034, 16, 1)
    else if @errorid = 21052 raiserror (21052, 16, 1)
    else if @errorid = 21054 raiserror (21054, 16, 1)
    else if @errorid = 21064 raiserror (21064, 16, 1)
    else if @errorid = 21161 raiserror (21161, 16, 1)
    else if @errorid = 20598 raiserror (20598, 16, 1, @param3, @param1, @param2)
GO
GRANT EXECUTE ON [sys].[sp_MSreplraiserror] TO [public] AS [dbo]
GO
