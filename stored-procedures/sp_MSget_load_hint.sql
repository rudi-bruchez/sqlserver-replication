SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_load_hint]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_load_hint] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_load_hint]
	@qualified_source_object_name [nvarchar](4000),
	@qualified_sync_object_name [nvarchar](4000),
	@primary_key_only [bit],
	@is_vertically_partitioned [bit]
WITH EXECUTE AS CALLER
AS
begin
set nocount on
declare @source_object_id int
      , @sync_object_id int
      , @index_id int
      , @load_ordering_hint nvarchar(max)
      , @retcode int
      , @index_column_name sysname
      , @index_column_is_descending bit
      , @first_index_column bit
      , @hint nvarchar(max)

set @retcode = 0 
exec @retcode = sys.sp_MSreplcheck_publish
if @@error <> 0 or @retcode <> 0
    return (1)

set @source_object_id = object_id(@qualified_source_object_name)
set @sync_object_id = object_id(@qualified_sync_object_name)
set @first_index_column = 1
set @index_id = null

select @index_id = index_id
  from sys.indexes inds
 where inds.type = 1 -- Consider clustered index only
   and inds.object_id = @source_object_id
   and (@primary_key_only = 0 or inds.is_primary_key = 1)

if @index_id is not null
begin
    if @is_vertically_partitioned = 1
    begin
        if exists (select indcols.column_id 
                     from sys.index_columns indcols
                    where indcols.index_id = @index_id
                      and indcols.object_id = @source_object_id 
                      and indcols.column_id <> 0
                      and indcols.column_id not in (select cols.column_id
                                                      from sys.columns cols
                                                inner join sys.columns synccols
                                                        on cols.name = synccols.name
                                                       and synccols.object_id = @sync_object_id
                                                     where cols.object_id = @source_object_id
                                                and isnull(cols.is_computed, 0) <> 1))
        begin
            set @index_id = null
        end
    end
    else
    begin
        if exists (select indcols.column_id
                     from sys.index_columns indcols
               inner join sys.columns cols
                       on indcols.column_id = cols.column_id
                      and cols.object_id = @source_object_id
                      and indcols.index_id = @index_id
                      and indcols.object_id = @source_object_id
                    where indcols.column_id <> 0
                      and isnull(cols.is_computed, 0) = 1)
        begin
            set @index_id = null
        end
    end
end
    
if @index_id is not null
begin
    declare hIndexColumns cursor local
       for select cols.name, isnull(indcols.is_descending_key,0) 
             from sys.index_columns indcols
       inner join sys.columns cols
               on cols.column_id = indcols.column_id -- The join should filter out uniquefying columns
              and cols.object_id = @source_object_id
              and indcols.object_id = @source_object_id
              and indcols.index_id = @index_id
            where isnull(indcols.is_included_column, 0) = 0
         order by indcols.key_ordinal asc
    open hIndexColumns
    fetch hIndexColumns into @index_column_name, @index_column_is_descending
    while (@@fetch_status <> -1)
    begin
        if @first_index_column = 1
        begin
            set @hint = 'ORDER(' + quotename(@index_column_name) 
            set @first_index_column = 0
        end
        else
        begin
            set @hint = @hint + N',' + quotename(@index_column_name)
        end

        set @hint = @hint + case when @index_column_is_descending = 1 then N' DESC' else N' ASC' end
        fetch hIndexColumns into @index_column_name, @index_column_is_descending
    end    
    set @hint = @hint + N')'
    close hIndexColumns
    deallocate hIndexColumns
    select @hint, convert(int, 16)
end

return (0)     
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_load_hint] TO [public] AS [dbo]
GO
