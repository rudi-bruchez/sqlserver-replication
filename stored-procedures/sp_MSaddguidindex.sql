SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddguidindex]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddguidindex] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddguidindex]
	@publication [sysname],
	@source_owner [sysname],
	@source_table [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @indexname     nvarchar(270)
    declare @colname    nvarchar(270)
    declare @retcode int
    declare @qualified_name nvarchar(517)
    declare @filegroup  nvarchar(258)
    declare @colid        int
    declare @columns    varbinary(128)
    declare @id            int
    declare @pubid        uniqueidentifier
      declare @mergepublish    int
    declare @column_name sysname

    -- Security check
    exec @retcode = dbo.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

      select @mergepublish = 0x4000
      
    select @pubid = pubid from dbo.sysmergepublications 
        where name=@publication and publisher=publishingservername() and publisher_db=db_name()
    select @qualified_name = QUOTENAME(@source_owner) + '.' + QUOTENAME(@source_table)
    select @id = object_id(@qualified_name)

    select @colid=column_id, @column_name = name from sys.columns where object_id=@id and is_rowguidcol=1

    begin tran
    save tran sp_MSaddguidindex
    exec %%Object(MultiName=@qualified_name).LockMatchID(ID=@id, Exclusive = 1, BindInternal = 0)
    --exec %%Object(MultiName=@qualified_name).LockExclusiveMatchID(ID=@id)
    if @@error<>0
    begin
        rollback tran sp_MSaddguidindex
        commit tran
        return (1)
    end

    exec %%ColumnEx(ObjectID=@id,Name=@column_name).SetMergePublished(Value=1)
    if @@ERROR<>0
    begin
        rollback tran sp_MSaddguidindex
        commit tran
        return (1)
    end
    commit tran

    /* Update the columns bitmaps in all articles at the current publisher that share the same table */
    declare artpubs CURSOR LOCAL FAST_FORWARD FOR 
        select DISTINCT pubid from dbo.sysmergearticles with (rowlock) where objid=@id and pubid
            in ( select pubid from dbo.sysmergepublications where UPPER(publisher) = UPPER(publishingservername()) 
                and publisher_db = db_name())
    FOR READ ONLY
    open artpubs
    fetch next from artpubs into @pubid
     
    while (@@fetch_status <> -1)
        begin
            select @columns=columns from dbo.sysmergearticles with (rowlock) where objid=@id and pubid=@pubid
            exec @retcode = sys.sp_MSsetbit @columns OUTPUT, @colid
            if @retcode<>0 or @@ERROR<>0
                return (1)
            update dbo.sysmergearticles with (rowlock) set columns=@columns where objid=@id and pubid = @pubid
            if @@ERROR<>0
                return (1)
            fetch next from artpubs into @pubid
        end 
    close artpubs
    deallocate artpubs
   
    select @indexname = 'MSmerge_index_' + convert(nvarchar(36), @id)

    select @colname=name from sys.columns where object_id=@id and is_rowguidcol=1
    if (@colname is null)
        return (1)
    
    /* Alter the source table to add a rowguid column index */
    if (not exists (select * from sys.indexes
        where object_id = object_id(@qualified_name) and
            @colname = index_col(@qualified_name, index_id, 1)
            and is_unique = 1 and 
            index_col(@qualified_name, index_id, 2) is null))
    begin
        declare @quoted_rgcol nvarchar(290)
        set @quoted_rgcol= quotename(@colname)

        -- Special case partitioned tables because we can not create a unique index on the rowguid column on such tables without
        -- putting it on a specific filegroup.

        -- Check if the table is partitioned.

        if not exists (select * from (sys.indexes as i INNER JOIN sys.partition_schemes as ps
                                                              ON (i.data_space_id = ps.data_space_id))
                        where (i.object_id = object_id(@qualified_name)) and
                            (i.index_id IN (0,1)))  -- to ensure that we are dealing with tables
        begin
            exec ('create unique index ' + @indexname  + ' on ' + @qualified_name + '(' +  @quoted_rgcol + ')')
            if @@ERROR <>0 return (1) 
        end
        else
        begin
            -- Table is partitioned.
            -- Find a filegroup that is not a destination for a partitioning scheme.
            select top 1 @filegroup = QUOTENAME(fg.name) from sys.filegroups as fg 
            left outer join sys.destination_data_spaces as ds 
                on ds.data_space_id = fg.data_space_id
            where ds.data_space_id is null 
            order by fg.name

            if @filegroup is null
            begin
                select top 1 @filegroup = QUOTENAME(fg.name) from sys.destination_data_spaces as ds 
                join sys.filegroups as fg 
                    on ds.data_space_id = fg.data_space_id
                order by ds.data_space_id
            end

            if @filegroup is null
            begin
                return (1)
            end
            
            exec ('create unique index ' + @indexname  + ' on ' + @qualified_name + '(' +  @quoted_rgcol + ') on ' + @filegroup)
            if @@ERROR <>0 return (1) 
        end
    end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSaddguidindex] TO [public] AS [dbo]
GO
