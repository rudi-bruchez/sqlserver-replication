SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSconflicttableexists]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSconflicttableexists] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSconflicttableexists]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@exists [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @tablename sysname
    declare @ownername sysname
    declare @qualified_tablename nvarchar(270)
    
    EXEC @retcode = dbo.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0 return(1)


    set @exists= 0
    
    select top 1 @tablename= conflict_table,
                 @ownername= destination_owner
         from dbo.sysmergearticles where pubid=@pubid and artid=@artid

    if @@error<>0 return 1

    if @tablename is not null
    begin
        if @ownername is null
        begin
            set @qualified_tablename= quotename(@tablename)
        end
        else
        begin
            set @qualified_tablename= quotename(@ownername) + '.' + quotename(@tablename)
        end

        if object_id(@qualified_tablename) is not null
        begin
            set @exists= 1
        end
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSconflicttableexists] TO [public] AS [dbo]
GO
