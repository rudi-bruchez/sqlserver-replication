SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreset_synctran_bit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreset_synctran_bit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreset_synctran_bit]
	@owner [sysname],
	@table [sysname]
WITH EXECUTE AS CALLER
AS
declare @qualified_name nvarchar(300)
    declare @tabid    int
    declare @retcode int

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe    
    if @retcode<>0 or @@error<>0
        return 1

    if @owner = N''
        select @qualified_name = @table
    else
        select @qualified_name = quotename(@owner) + '.' + quotename(@table) 

    BEGIN TRANSACTION
    -- Unmark synctran bit
    select @tabid = object_id(@qualified_name)
    if not (@tabid is null)
    begin
        IF ISNULL(OBJECTPROPERTY(@tabid, 'TableIsMemoryOptimized'), 0) <> 1
        Begin
            EXEC %%Object(MultiName = @qualified_name).LockMatchID(ID = @tabid, Exclusive = 1, BindInternal = 0)
            --EXEC %%Object(MultiName = @qualified_name).LockExclusiveMatchID(ID = @tabid)
            if @@error = 0
                EXEC %%Relation(ID = @tabid).SetSyncTranSubscribe(Value = 0)
        End
    end
    COMMIT TRANSACTION
    return(0)
GO
GRANT EXECUTE ON [sys].[sp_MSreset_synctran_bit] TO [public] AS [dbo]
GO
