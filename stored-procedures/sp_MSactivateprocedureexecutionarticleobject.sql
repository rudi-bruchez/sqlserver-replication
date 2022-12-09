SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSactivateprocedureexecutionarticleobject]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSactivateprocedureexecutionarticleobject] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSactivateprocedureexecutionarticleobject]
	@qualified_procedure_execution_object_name [nvarchar](517),
	@is_repl_serializable_only [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    if @@trancount < 1 return 1
    
    if sessionproperty('replication_agent') <> 1 return 1
    
    if object_id(N'dbo.syspublications', 'U') is null return 1
    
    declare @retcode int
          , @is_execution_replicated bit
          , @current_is_repl_serializable_only bit
          , @object_id int
          , @error int
    set @retcode = 0

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    set @object_id = object_id(@qualified_procedure_execution_object_name)
    select @is_execution_replicated = is_execution_replicated
         , @current_is_repl_serializable_only = is_repl_serializable_only
      from sys.procedures
     where object_id = @object_id
    
    if @is_execution_replicated = 0 or 
       @current_is_repl_serializable_only = 0 and @is_repl_serializable_only = 1
    begin
        exec %%Object(MultiName = @qualified_procedure_execution_object_name).LockMatchID(ID = @object_id, Exclusive = 1, BindInternal = 0)
        set @error = @@error if @error <> 0 begin raiserror(@error, 16, -1) return 1 end
        exec %%Module(ID = @object_id).SetProcReplicated(Value = 1)
        set @error = @@error if @error <> 0 begin raiserror(@error, 16, -1) return 1 end
        if @is_repl_serializable_only = 1
        begin
            exec %%Module(ID = @object_id).SetProcReplSerialOnly(Value = 1)
            set @error = @@error if @error <> 0 begin raiserror(@error, 16, -1) return 1 end
        end
    end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSactivateprocedureexecutionarticleobject] TO [public] AS [dbo]
GO
