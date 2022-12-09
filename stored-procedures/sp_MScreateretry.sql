SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreateretry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreateretry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreateretry]
WITH EXECUTE AS CALLER
AS
declare @tname sysname
    declare @pname sysname
    declare @tempname sysname
    declare @guid uniqueidentifier
    declare @guidstr varchar(40)
    declare @retcode smallint

    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1
   
    set @guid = newid()
    exec @retcode=sys.sp_MSguidtostr @guid, @guidstr out
    if @retcode<>0 or @@ERROR<>0 return (1)
    set @tempname = '##retry_' + @guidstr

    exec ('create table ' + @tempname + ' (tablenick int NOT NULL, rowguid uniqueidentifier ROWGUIDCOL default newid() not null, errcode int NOT NULL, errtext nvarchar(255) NULL, type tinyint NOT NULL)' )

    if (@@error <> 0)
        begin
        RAISERROR(15001, 16, -1, @tempname)
        return (1)
        end

    set  @tname = @tempname
    set @tempname = '##insert_' + @guidstr

    exec @retcode = sys.sp_MSmaketempinsertproc @tname, @tempname
    if  @@ERROR <>0 or @retcode<>0 return (1)

    select @pname = @tempname
    select @tname, @pname
    return (0)  
GO
GRANT EXECUTE ON [sys].[sp_MScreateretry] TO [public] AS [dbo]
GO
