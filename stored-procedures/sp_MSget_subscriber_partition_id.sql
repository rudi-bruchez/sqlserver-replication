SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_subscriber_partition_id]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_subscriber_partition_id] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_subscriber_partition_id]
	@publication [sysname],
	@partition_id [int] OUTPUT,
	@maxgen_whenadded [bigint] OUTPUT,
	@host_name_override [sysname],
	@suser_sname_override [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    
    declare @partition_id_eval_proc nvarchar(270), @retcode int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@ERROR<>0
        return 1
                    
    select @partition_id_eval_proc = partition_id_eval_proc from dbo.sysmergepublications
    where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    
    if @partition_id_eval_proc is not null
    begin
        select @partition_id_eval_proc = 'dbo.' + @partition_id_eval_proc
        
        exec @retcode = @partition_id_eval_proc @partition_id OUTPUT, 
                                                @maxgen_whenadded OUTPUT,
                                                @host_name_override,
                                                @suser_sname_override
    
        if @retcode <> 0 or @@error <> 0
            return 1
    end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_subscriber_partition_id] TO [public] AS [dbo]
GO
