SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfillupmissingcols]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfillupmissingcols] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfillupmissingcols]
	@publication [sysname],
	@source_table [sysname]
WITH EXECUTE AS CALLER
AS
declare @sync_objid         int
declare @missingcolid        int
declare @missing_cols        varbinary(128)
declare @excludedcolid        int
declare @excludedbm            varbinary(128)
declare @excludedcolcnt        int
declare @missing_col_count    int
declare @maxcolid            int
declare @column_tracking    bit
declare @id                    int
declare @pubid                uniqueidentifier
declare @missingindex        int
declare @retcode            int
declare @missing_index_absolute int

-- Security check
exec @retcode= dbo.sp_MSreplcheck_publish
if @@error <> 0 or @retcode <> 0 return (1)

select @id = object_id(@source_table)
select @excludedcolcnt = 0
select @pubid=pubid from dbo.sysmergepublications where name=@publication and publisher=publishingservername() and publisher_db=db_name()
select @sync_objid=sync_objid from dbo.sysmergearticles where objid = @id and pubid=@pubid
select @excludedbm = 0x00
select @missingcolid = 1 --instead of using the minimal column_id in sys.columns with the same id, as we used to do 
select TOP 1 @maxcolid = column_id from sys.columns where object_id=@id order by column_id DESC
 
-- check if this is a republisher. If it is then pick the missing_cols value from the row for the subscriber.
select @missing_cols = missing_cols, 
       @missing_col_count = missing_col_count
    from dbo.sysmergearticles where objid=@id and pubid<>@pubid and sys.fn_MSmerge_islocalpubid(pubid)=0

if @missing_cols is null
begin
    select @missing_cols = missing_cols, 
        @missing_col_count = missing_col_count
        from dbo.sysmergearticles where objid = @id and pubid=@pubid
end

while (@missingcolid <= @maxcolid)
begin
    if exists (select * from sys.columns where column_id = @missingcolid and object_id = @id and 
                is_computed <> 1 and system_type_id <> type_id('timestamp') and
                name not in (select name from sys.columns where object_id = @sync_objid))
    begin
        select @excludedcolcnt = @excludedcolcnt + 1
        select @missingindex = count(*) from sys.columns where object_id=@id and column_id<=@missingcolid and is_computed <> 1 and system_type_id <> type_id('timestamp')

        -- Get the absolute index of the excluded column by taking into consideration the
        -- missing column bitmask.
        exec sys.sp_MSget_absolute_colid @missing_cols, @missingindex, @missing_index_absolute OUTPUT
        
        exec sys.sp_MSsetbit @excludedbm OUTPUT, @missing_index_absolute
    end
    set @missingcolid = @missingcolid + 1
end

UPDATE dbo.sysmergearticles set excluded_col_count = @excludedcolcnt, 
                            excluded_cols = @excludedbm,
                            missing_col_count = @missing_col_count,
                            missing_cols = @missing_cols
        where objid = @id and pubid=@pubid
GO
GRANT EXECUTE ON [sys].[sp_MSfillupmissingcols] TO [public] AS [dbo]
GO
