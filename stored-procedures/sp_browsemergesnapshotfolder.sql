SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_browsemergesnapshotfolder]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_browsemergesnapshotfolder] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_browsemergesnapshotfolder]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE @dbname sysname
    DECLARE @alt_directory_type INT
    DECLARE @directory_type INT
    declare @retcode int
    
    SELECT @alt_directory_type = 25
    SELECT @directory_type = 7

    EXEC @retcode = dbo.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    IF object_id(N'sysmergepublications') is not NULL AND
       object_id(N'sysmergeschemachange') is not NULL
    BEGIN
        SELECT 'snapshot_folder' = schematext 
          FROM dbo.sysmergeschemachange sc 
    INNER JOIN dbo.sysmergepublications mp
            ON sc.pubid = mp.pubid
         WHERE mp.name = @publication
           AND upper(mp.publisher) = upper(publishingservername())
           AND publisher_db = db_name()  
           AND (schematype = @directory_type OR schematype = @alt_directory_type)
      ORDER BY schematype desc
    END  
    ELSE
    BEGIN
        SELECT @dbname = DB_NAME()
        RAISERROR(21147, 16, -1, @dbname)
        RETURN 1
    END
END
GO
GRANT EXECUTE ON [sys].[sp_browsemergesnapshotfolder] TO [public] AS [dbo]
GO
