SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addarticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addarticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addarticle]
	@publication [sysname],
	@article [sysname],
	@source_table [nvarchar](386),
	@destination_table [sysname],
	@vertical_partition [nchar](5),
	@type [sysname],
	@filter [nvarchar](386),
	@sync_object [nvarchar](386),
	@ins_cmd [nvarchar](255),
	@del_cmd [nvarchar](255),
	@upd_cmd [nvarchar](255),
	@creation_script [nvarchar](255),
	@description [nvarchar](255),
	@pre_creation_cmd [nvarchar](10),
	@filter_clause [nvarchar](max),
	@schema_option [varbinary](8),
	@destination_owner [sysname],
	@status [tinyint],
	@source_owner [sysname],
	@sync_object_owner [sysname],
	@filter_owner [sysname],
	@source_object [sysname],
	@artid [int] OUTPUT,
	@auto_identity_range [nvarchar](5),
	@pub_identity_range [bigint],
	@identity_range [bigint],
	@threshold [int],
	@force_invalidate_snapshot [bit],
	@use_default_datatypes [bit],
	@identityrangemanagementoption [nvarchar](10),
	@publisher [sysname],
	@fire_triggers_on_snapshot [nvarchar](5)
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    DECLARE @cmd nvarchar(4000)
                ,@retcode int
                ,@publisher_type sysname

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo  @publisher        = @publisher,
                                                                        @rpcheader        = @cmd OUTPUT,
                                                                        @publisher_type    = @publisher_type OUTPUT
    
    IF @retcode <> 0
        RETURN (@retcode)

    select @publisher = UPPER(@publisher) 
            ,@cmd = @cmd + N'sys.sp_MSrepl_addarticle'
    
    EXEC @retcode = @cmd
                    @publication,
                    @article,
                    @source_table,
                    @destination_table,
                    @vertical_partition,
                    @type,
                    @filter,
                    @sync_object,
                    @ins_cmd,
                    @del_cmd,
                    @upd_cmd,
                    @creation_script,
                    @description,
                    @pre_creation_cmd,
                    @filter_clause,
                    @schema_option,
                    @destination_owner,
                    @status,
                    @source_owner,
                    @sync_object_owner,
                    @filter_owner,
                    @source_object,
                    @artid OUTPUT,
                    @identityrangemanagementoption,
                    @auto_identity_range,
                    @pub_identity_range,
                    @identity_range,
                    @threshold,
                    @force_invalidate_snapshot,
                    @use_default_datatypes,
                    @publisher,
                    @publisher_type,
                    @fire_triggers_on_snapshot

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addarticle] TO [public] AS [dbo]
GO
