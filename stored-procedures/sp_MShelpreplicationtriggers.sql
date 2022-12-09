SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpreplicationtriggers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpreplicationtriggers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpreplicationtriggers]
	@object_name [sysname],
	@object_schema [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
          , @object_id int
          , @guidstr nvarchar(100)

    set @retcode = 0
    set @guidstr = null

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    set @object_id = object_id(quotename(@object_schema) + N'.' +  quotename(@object_name))

    if @object_id is null return 0 -- There is nothing to do here

    if object_id(N'dbo.sysarticleupdates', 'U') is not null
    begin
        select 'trigger_name' = object_name(sync_upd_trig)
          from dbo.sysarticleupdates updates
    inner join dbo.sysarticles arts -- Can't have synctran triggers on 
            on updates.artid = arts.artid
         where arts.objid = @object_id
    end

    if object_id(N'dbo.sysmergearticles', 'U') is not null
    begin
        -- Note: All merge articles of the same source object share
        -- the same article id.

        select @guidstr = sys.fn_MSguidtostr(artid)
          from dbo.sysmergearticles
         where objid = @object_id

        if @guidstr is not null
        begin
            declare @ins_trigger_name sysname
                  , @upd_trigger_name sysname
                  , @del_trigger_name sysname
                  , @yukon_ins_trigger_name sysname
                  , @yukon_upd_trigger_name sysname
                  , @yukon_del_trigger_name sysname
                            
            set @ins_trigger_name = N'ins_' + @guidstr
            set @upd_trigger_name = N'upd_' + @guidstr
            set @del_trigger_name = N'del_' + @guidstr
            set @yukon_ins_trigger_name = N'MSmerge_ins_' + @guidstr
            set @yukon_upd_trigger_name = N'MSmerge_upd_' + @guidstr
            set @yukon_del_trigger_name = N'MSmerge_del_' + @guidstr

            select 'trigger_name' = name
              from sys.triggers
             where parent_class = 1
               and parent_id = @object_id
               and name in (@ins_trigger_name
                           ,@upd_trigger_name
                           ,@del_trigger_name
                           ,@yukon_ins_trigger_name
                           ,@yukon_upd_trigger_name
                           ,@yukon_del_trigger_name)
                        
        end
    end

    return @retcode    
end
GO
GRANT EXECUTE ON [sys].[sp_MShelpreplicationtriggers] TO [public] AS [dbo]
GO
