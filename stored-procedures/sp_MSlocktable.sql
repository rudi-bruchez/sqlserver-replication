SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSlocktable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSlocktable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSlocktable]
	@ownername [sysname],
	@tablename [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @retcode            int
            ,@procname            sysname
            ,@objid                 int
            ,@qualified_name        nvarchar(300)
            ,@spretcode int
            ,@spcall nvarchar(256)
    
    if @ownername is null
        set @qualified_name= QUOTENAME(@tablename)
    else
        set @qualified_name= QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)

    select @objid = object_id(@qualified_name)
    if @objid is NULL
        select @objid = object_id from sys.objects where name=@tablename
    if @objid is null
        return (1)
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @objid = @objid 
    if ((@retcode <> 0) or (@@error <> 0))
        return 1

    if 1=sys.fn_MSuselightweightreplication(null, null, null, null, null, null, @objid)
    begin
        --
        -- For security: break ownership chain as
        -- we have no control over the proc name is
        --
        select @procname= 'dbo.MSmerge_lws_sp_multi_' + procname_postfix from dbo.sysmergearticles where objid = @objid
                            and (1 = {fn ISPALUSER(pubid)})
        select @spcall = N'exec @p1 = ' + @procname + N' @action = 4 '
        exec @retcode = sys.sp_executesql @stmt = @spcall
            ,@params = N'@p1 int output'
            ,@p1 = @spretcode output
        IF @@ERROR<>0 or @retcode<>0 or @spretcode != 0 
            RETURN (1)
    end            
    else
    begin
        --
        -- For security: break ownership chain as
        -- we have no control over the proc name is
        --
        select @procname = 'dbo.' + select_proc from dbo.sysmergearticles where objid = @objid
                        and (1 = {fn ISPALUSER(pubid)})
        select @spcall = N'exec @p1 = ' + @procname + N' @maxschemaguidforarticle = NULL, @type = 7 '
        exec @retcode = sys.sp_executesql @stmt = @spcall
            ,@params = N'@p1 int output'
            ,@p1 = @spretcode output
        IF @@ERROR<>0 or @retcode<>0 or @spretcode != 0 
            RETURN (1)
    end
end
GO
GRANT EXECUTE ON [sys].[sp_MSlocktable] TO [public] AS [dbo]
GO
