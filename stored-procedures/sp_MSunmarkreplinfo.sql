SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSunmarkreplinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSunmarkreplinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSunmarkreplinfo]
	@object [sysname],
	@owner [sysname],
	@type [smallint]
WITH EXECUTE AS CALLER
AS
declare @id    int
    declare @qualified_name            nvarchar(517)
    declare @retcode                int

    exec @retcode = sys.sp_MSreplcheck_subscribe_withddladmin
    if @@error<>0 or @retcode<>0
        return (1)

    if @owner is NULL or @owner=''
        select @owner = schema_name(schema_id) from sys.objects where name=@object
    select @qualified_name = QUOTENAME(@owner) + '.' + QUOTENAME(@object) 

    if object_id(@qualified_name, 'U') is NULL
        return 0

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
    begin
        if @type = 0    /* type = 0, unmark; else mark the bit */
            EXEC %%Relation(ID = @id).SetMergePublished(Value = 0, SetColumns = 1)
        else
            EXEC %%Relation(ID = @id).SetMergePublished(Value = 1, SetColumns = 1)
    end
    COMMIT TRANSACTION
GO
GRANT EXECUTE ON [sys].[sp_MSunmarkreplinfo] TO [public] AS [dbo]
GO
