SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_copymergesnapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_copymergesnapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_copymergesnapshot]
	@publication [sysname],
	@destination_folder [nvarchar](255)
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE @retcode       int
    DECLARE @source_folder nvarchar(255)
    SELECT @retcode = 0
    
    EXEC @retcode = dbo.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    CREATE TABLE #snapshot_folders
    (
        id              int identity, 
        snapshot_folder nvarchar(255) collate database_default
    )
    IF @@ERROR <> 0
    BEGIN
        RETURN 1
    END

    INSERT INTO #snapshot_folders
    EXEC @retcode = sys.sp_browsemergesnapshotfolder @publication = @publication
    IF @retcode <> 0 OR @@ERROR <> 0
    BEGIN
        GOTO Failure
    END
    
    SELECT @source_folder = (select top 1 snapshot_folder FROM #snapshot_folders ORDER BY id ASC)
    IF @@ERROR <> 0
    BEGIN
        GOTO Failure
    END        
    SET ROWCOUNT 0    

    EXEC @retcode = sys.sp_MScopysnapshot @source_folder,
                                          @destination_folder
    IF @retcode <> 0 OR @@ERROR <> 0 
    BEGIN
        GOTO Failure
    END

    DROP TABLE #snapshot_folders
    RETURN 0
Failure:
    SET ROWCOUNT 0    
    DROP TABLE #snapshot_folders        
    RETURN 1
END
GO
GRANT EXECUTE ON [sys].[sp_copymergesnapshot] TO [public] AS [dbo]
GO
