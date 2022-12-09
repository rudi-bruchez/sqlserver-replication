SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSactivatelogbasedarticleobject]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSactivatelogbasedarticleobject] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSactivatelogbasedarticleobject]
	@qualified_logbased_object_name [nvarchar](517)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    if @@trancount < 1 return 1

    if sessionproperty('replication_agent') <> 1 return 1

    if object_id(N'dbo.syspublications', 'U') is null return 1
    
    declare @retcode int
          , @is_replicated bit
          , @object_id int
          , @error int
    set @retcode = 0
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1
    
    set @is_replicated = null
    set @object_id = object_id(@qualified_logbased_object_name)
    select @is_replicated = is_replicated
      from sys.tables
     where object_id = @object_id

    if @is_replicated is null
    begin
        select @is_replicated = is_replicated
          from sys.views
         where object_id = @object_id
    end

    if @is_replicated = 0
    begin
        exec %%Object(MultiName = @qualified_logbased_object_name).LockMatchID(ID = @object_id, Exclusive = 1, BindInternal = 0)
        set @error = @@error if @error <> 0 begin raiserror(@error, 16, -1) return 1 end
        exec %%Relation(ID = @object_id).SetReplicated(Value = 1)
        set @error = @@error if @error <> 0 begin raiserror(@error, 16, -1) return 1 end
    end
    return 0 

end
GO
GRANT EXECUTE ON [sys].[sp_MSactivatelogbasedarticleobject] TO [public] AS [dbo]
GO
