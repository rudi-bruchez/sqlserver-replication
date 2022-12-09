SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpreplicationoption]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpreplicationoption] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpreplicationoption]
	@optname [sysname]
WITH EXECUTE AS CALLER
AS
DECLARE @optbit bit
    DECLARE @retcode int


    IF @optname IS NOT NULL AND LOWER(@optname collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('transactional','merge')
    BEGIN
        RAISERROR(21014, 16, -1)
        GOTO FAILURE
    END
    SELECT optname, value, major_version, minor_version, revision 
        FROM master.dbo.MSreplication_options
        WHERE
            optname = @optname OR
            @optname = NULL

    RETURN(0)

FAILURE:
    RETURN(1)
GO
GRANT EXECUTE ON [sys].[sp_helpreplicationoption] TO [public] AS [dbo]
GO
