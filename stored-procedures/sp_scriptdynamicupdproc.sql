SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_scriptdynamicupdproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_scriptdynamicupdproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_scriptdynamicupdproc]
	@artid [int]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode int
    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        return (1)
    end
    --
    -- call core function
    --
    exec @retcode = sys.sp_scriptupdproccore 
             @artid = @artid
            ,@format = 2        -- MCALL format
            ,@mode = 2          -- dynamic scripting
            ,@publishertype = 1 -- SQL Server publisher
    return @retcode
end

--
-- Name: sp_scriptvupdproc
--
-- Owner: KaushikC
--
-- Description: This procs is used for scripting VCALL update custom procedure
-- used for command distribution. Used specifically for updating subscriber articles.
-- Processing is similar to MCALL update procedure, in addition the version is also passed in
--
-- Parameter: Refer to the comments in the create procedure statement
--
-- Returns: 1 or 0   0 = success
--
-- Security: Public procedure - internal security check. 
--
raiserror('Creating procedure sp_scriptvupdproc', 0,1)
GO
GRANT EXECUTE ON [sys].[sp_scriptdynamicupdproc] TO [public] AS [dbo]
GO
