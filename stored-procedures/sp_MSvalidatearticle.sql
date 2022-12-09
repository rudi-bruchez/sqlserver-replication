SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSvalidatearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSvalidatearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSvalidatearticle]
	@artid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@expected_rowcount [bigint] OUTPUT,
	@expected_checksum [numeric](18, 0) OUTPUT,
	@validation_type [int],
	@full_or_fast [tinyint]
WITH EXECUTE AS CALLER
AS
declare @objid int
    declare @syncobjid int
    declare @owner sysname
    declare @object sysname
    declare @view_type tinyint
    declare @temp_view tinyint
    declare @retcode int
    declare @rowcount_only int
    declare @source_objid int
    declare @column_list nvarchar(max)
    /*
    ** Check to see if current publication has permission
    */
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
            RAISERROR (21723, 16, -1, 'sp_MSvalidatearticle')
            return 1
        end
        else
        begin
            RAISERROR (14126, 11, -1)
            return 1
        end
    end
    
    /* 
    The @rowcount_only param is overloaded for shiloh release due to backward compatibility concerns.
    In shiloh, the checksum functionality has changed.   So 7.0 subscribers will have the old checksum 
    routines, which generate different CRC values, and do not have functionality for vertical partitions,
    or logical table structures where column offsets differ (due to ALTER TABLEs that DROP and ADD columns).

    In 7.0, this was a bit column.  0 meant do not do just a rowcount - do a checksum.  1 meant just do a 
    rowcount.

    For Shiloh, this parameter is changed to a smallint with these options:
    0 - Do a 7.0 compatible checksum
    1 - Do a rowcount check only
    2 - Use new Shiloh checksum functionality.  Note that because 7.0 subscribers will 
    take this parameter as a bit type, not a smallint, it will be interpreted as simply
    ON.  That means that passing a 2, and having a 7.0 subscriber, will result in the 7.0
    subscriber doing only rowcount validation.   The Shiloh subscribers will do both
    rowcount and checksum.  If you want 7.0 subscribers to do checksum validation, use 
    the value of 0 for this parameter.   Shiloh subscribers can do the 7.0 compatible 
    checksum, but that checksum has the same 7.0 limitations for vertical partitions 
    and differences in physical table structure.)
    */
    if @validation_type = 3 or @validation_type = 2
        set @rowcount_only  = 2
    else
        set @rowcount_only  = 1

    select @syncobjid = sync_objid, @objid = objid, @view_type = view_type from
                dbo.sysmergearticles where pubid = @pubid and artid = @artid
    select @source_objid = @objid       
    if (@syncobjid is not null and @syncobjid <> 0)
        set @objid = @syncobjid
    select @object = name, @owner = SCHEMA_NAME(schema_id) from sys.objects where object_id = @objid
        -- if sync object is a temp view, we can't do this...
    set @temp_view = 2
    if @view_type = @temp_view
    begin
        RAISERROR (20069, 16, -1)
        return 1
    end
    --else if (@view_type = 1 and @rowcount_only = 0)
    --begin
    --    RAISERROR (21017, 16, -1)
    --    return 1
    --end
    -- call with blob_cols_at_the_end =0 so we get the actual order of the columns in the article not non-blob followed by
    -- blob
    exec @retcode = sys.sp_MSgetviewcolumnlist @pubid, @source_objid, @column_list OUTPUT, @blob_cols_at_the_end=0
    if @@ERROR<>0 OR @retcode <> 0
        return @retcode

    exec @retcode = sys.sp_MStable_validation @object, @expected_rowcount OUTPUT, @expected_checksum  OUTPUT, @rowcount_only, @owner, @full_or_fast, 0, NULL, @column_list
    if @@error<>0 return(1)
    return @retcode
    
GO
GRANT EXECUTE ON [sys].[sp_MSvalidatearticle] TO [public] AS [dbo]
GO
