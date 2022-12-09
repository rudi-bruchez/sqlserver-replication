SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSunmarkschemaobject]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSunmarkschemaobject] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSunmarkschemaobject]
	@object [sysname],
	@owner [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @qualified_name nvarchar(517)
    declare @id int
    declare @retcode int

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error<>0 or @retcode <>0
        return (1)

    if (@owner is null or @owner = N'')
    begin
        select @owner = schema_name()
    end
    select @qualified_name = QUOTENAME(@owner) + '.' + QUOTENAME(@object)

    BEGIN TRANSACTION
    select @id = object_id(@qualified_name)
    if not (@id is null)
    begin
        EXEC %%Object(MultiName = @qualified_name).LockMatchID(ID = @id, Exclusive = 1, BindInternal = 0)
        --EXEC %%Object(MultiName = @qualified_name).LockExclusiveMatchID(ID = @id)
        if @@error <> 0
            select @id = null
    end

    if not (@id is null)
        EXEC %%Object(ID = @id).SetSchemaPublished(Value = 0)
    COMMIT TRANSACTION

    return 0    
end
GO
GRANT EXECUTE ON [sys].[sp_MSunmarkschemaobject] TO [public] AS [dbo]
GO
