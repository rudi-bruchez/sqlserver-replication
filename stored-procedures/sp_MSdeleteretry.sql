SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdeleteretry]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdeleteretry] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdeleteretry]
	@temptable [nvarchar](386),
	@tablenick [int],
	@rowguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @guidstr nvarchar(38)
    declare @nickstr nvarchar(12)
    declare @retcode int

    declare @quotedtemptable nvarchar(388)

    /*
    ** do permission checking
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if @retcode<>0 or @@ERROR<>0 return (1)

    /*
    ** Modify temp table, granted to public.
    */
    
    set @nickstr = convert(nchar, @tablenick)
    set @guidstr = '''' + convert(nchar(36), @rowguid) + ''''

    select @quotedtemptable = quotename(@temptable)

    execute ('delete from ' + @quotedtemptable + ' where tablenick = ' +
              @nickstr + ' and rowguidcol = ' + @guidstr)
    IF @@ERROR <>0 RETURN (1)
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSdeleteretry] TO [public] AS [dbo]
GO
