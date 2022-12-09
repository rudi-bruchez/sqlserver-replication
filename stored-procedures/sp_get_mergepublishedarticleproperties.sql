SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_get_mergepublishedarticleproperties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_get_mergepublishedarticleproperties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_get_mergepublishedarticleproperties]
	@source_object [sysname],
	@source_owner [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @retcode int
    /*
    ** Check for dbo permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 
        return (1)


    /*
    ** Declarations.
    */

    declare @objid int
	declare @partition_options tinyint	

    IF object_id('sysmergearticles') is NULL
        RETURN (0)

    if @source_object IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@source_object', 'sp_get_mergepublishedarticleproperties')
        RETURN (1)
    END

	if @source_owner IS NULL
	    select @objid = object_id(quotename(@source_object))
	else
	    select @objid = object_id(quotename(@source_owner) + '.' + quotename(@source_object))

    if @objid is NULL
    	RETURN(0)
    	
    if object_id('sysmergepartitioninfo') is not NULL
    begin
        select top 1 @partition_options = smpi.partition_options
	    	from dbo.sysmergepartitioninfo as smpi join sysmergearticles as sma
		        on sma.artid = smpi.artid
		        and sma.pubid = smpi.pubid
     		where @objid = sma.objid
     		order by sma.pubid
    end

    select top 1
	column_tracking as column_tracking,
	schema_option as schema_option,
	vertical_partition as vertical_partition,
	identity_support as identity_support,
	upload_options as subscriber_upload_options,
	well_partitioned_lightweight as well_partitioned_lightweight,
	delete_tracking as delete_tracking,
	compensate_for_errors as compensate_for_errors,
	pub_range as pub_range,
	range as range,
	threshold as threshold,
	@partition_options as partition_options,
	stream_blob_columns as stream_blob_columns
    from dbo.sysmergearticles
    where @objid = objid
    order by pubid

    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_get_mergepublishedarticleproperties] TO [public] AS [dbo]
GO
