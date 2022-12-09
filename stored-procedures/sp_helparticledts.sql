SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helparticledts]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helparticledts] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helparticledts]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */

    DECLARE @artid int
    DECLARE @pubid int
    DECLARE @retcode int
    declare @article_name sysname

    -- Security check: Sysadmins and db_owners only
    exec @retcode = sp_MSreplcheck_publish
    if @retcode <> 0 or @@error <> 0
    begin
        return 1
    end

   /*
    ** Check to see if the database has been activated for publication.
    */

    IF (SELECT category & 1
          FROM master.dbo.sysdatabases
         WHERE name = DB_NAME() collate database_default) = 0

    BEGIN
            RAISERROR (14013, 16, -1)
            RETURN (1)
    END


    /*
    ** Parameter Check:  @publication.
    ** Make sure that the publication exists.
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_helparticledts')
            RETURN (1)
        END

    EXECUTE @retcode = sys.sp_validname @publication

    IF @@ERROR <> 0 OR @retcode <> 0
    RETURN (1)

    declare @allow_dts bit

    SELECT @pubid = pubid, @allow_dts = allow_dts   
        FROM syspublications WHERE name = @publication

    IF @pubid IS NULL
        BEGIN
            RAISERROR (20026, 11, -1, @publication)
            RETURN (1)
        END


    if @allow_dts = 0
    begin
        RAISERROR ('The publication ''%s'' does not allow DTS.', 11, -1, @publication)
        RETURN (1)
    end

    /*
    ** Check to see that the article exists in sysarticles.
    ** Fetch the article identification number.
    */

    IF @article IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@article', 'sp_helparticledts')
            RETURN (1)
        END

    /*
    EXECUTE @retcode = sys.sp_validname @article

    IF @retcode <> 0
    RETURN (1)
    */

    SELECT @artid = artid, @article_name = name
      FROM sysarticles
     WHERE name = @article
       AND pubid = @pubid
    IF @artid IS NULL
        BEGIN
            RAISERROR (20027, 11, -1, @article)
            RETURN (1)
        END
    
    select 
        N'pre_script_ignore_error_task_name' = @article_name + N'_pre_ignore_error',
        N'pre_script_task_name' = @article_name + N'_pre',
        N'transformation_task_name' = @article_name,
        N'post_script_ignore_error_task_name' = @article_name + N'_post_ignore_error',
        N'post_script_task_name' = @article_name + N'_post'
GO
GRANT EXECUTE ON [sys].[sp_helparticledts] TO [public] AS [dbo]
GO
