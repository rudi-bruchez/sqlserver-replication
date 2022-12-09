SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetrowmetadatalightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetrowmetadatalightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetrowmetadatalightweight]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@type [tinyint] OUTPUT,
	@rowvector [varbinary](11) OUTPUT,
	@changedcolumns [varbinary](128) OUTPUT,
	@columns_enumeration [tinyint] OUTPUT,
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode	smallint
    declare @action		tinyint
    declare @procname	sysname
    declare @postfix	nchar(32)
	
	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1

    if (@tablenick is null)
    begin
        raiserror(14043, 16, -1, '@tablenick', 'sp_MSgetrowmetadatalightweight')
        return (1)
    end

    if (@rowguid is null)
    begin
        raiserror(14043, 16, -1, '@rowguid', 'sp_MSgetrowmetadatalightweight')
        return (1)
    end

	select @postfix= procname_postfix
		from dbo.sysmergearticles 
		where pubid = @pubid and nickname = @tablenick
	
	set @procname= quotename('MSmerge_lws_sp_multi_' + @postfix)

	-- Get the metadata type (and possibly rowvector, changedcolumns) of the row. 
    exec @retcode= @procname 
    					@action= 3,
    					@rowguid= @rowguid,
    					@type= @type output,
    					@rowvector= @rowvector output,
    					@changedcolumns= @changedcolumns output,
    					@columns_enumeration= @columns_enumeration output

    if @@error <>0 or @retcode <> 0 return (1)

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetrowmetadatalightweight] TO [public] AS [dbo]
GO
