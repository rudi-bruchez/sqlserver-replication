SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmergesubscribedb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmergesubscribedb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmergesubscribedb]
	@value [sysname],
	@create_ddl_triggers [bit],
	@whattocreate [smallint]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @retcode int
    
    -- Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0 RETURN(1)

    -- Parameter check: @value
    IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true','false')
    BEGIN
        RAISERROR(14137,16,-1)
        RETURN(1)
    END

    IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
    BEGIN
        execute @retcode = sys.sp_MScreate_mergesystables @whattocreate=@whattocreate
        if @@ERROR <> 0 or @retcode <> 0 return (1)

		if @create_ddl_triggers = 1
        begin
			if exists (select * from dbo.sysmergearticles)
			begin
				execute @retcode= sys.sp_MSrepl_ddl_triggers @type='merge', @mode='add'
				if @@ERROR <> 0 or @retcode <> 0 return (1)
			end
        end
    END
    
    -- We assume we will do nothing about disabling a subscriber
    
GO
GRANT EXECUTE ON [sys].[sp_MSmergesubscribedb] TO [public] AS [dbo]
GO
