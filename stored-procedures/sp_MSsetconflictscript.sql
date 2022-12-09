SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetconflictscript]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetconflictscript] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetconflictscript]
	@publication [sysname],
	@article [sysname],
	@conflict_script [nvarchar](255),
	@login [sysname],
	@password [nvarchar](524)
WITH EXECUTE AS CALLER
AS
declare @artid uniqueidentifier
    declare @pubid uniqueidentifier
    
    /*
    ** Check for publish permission.
    */
    declare @retcode int
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    select @pubid = pubid from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid IS NULL
        BEGIN
            RAISERROR (20026, 16, -1, @publication)
            RETURN (1)
        END
    
    select @artid = artid FROM dbo.sysmergearticles WHERE name = @article   AND pubid = @pubid
    if @artid IS NULL
        BEGIN
            RAISERROR (20027, 16, -1, @article)
            RETURN (1)
        END

    update dbo.sysmergearticles set conflict_script = @conflict_script where artid = @artid and pubid=@pubid
    if @@ERROR <> 0
        return (1)
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetconflictscript] TO [public] AS [dbo]
GO
