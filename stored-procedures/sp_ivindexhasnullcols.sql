SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_ivindexhasnullcols]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_ivindexhasnullcols] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_ivindexhasnullcols]
	@viewname [sysname],
	@fhasnullcols [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
   declare @f_ind_unique bit
            ,@f_ind_clustered bit
            ,@ivobject_id int
            ,@indkey int
            ,@key sysname
			,@retcode int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    --
    -- validate view object
    --
    select @ivobject_id = object_id(@viewname)
            ,@fhasnullcols = 0
            
    if (@ivobject_id IS NULL or @ivobject_id = 0)
    begin
        raiserror(15390, 16, 1, @viewname)
        return 1
    end

    --
    -- get the clustered index and validate
    --
    select @f_ind_unique = case (status & 2) when 0 then 0 else 1 end
            ,@f_ind_clustered = case (status & 16) when 0 then 0 else 1 end 
    from dbo.sysindexes
    where id = @ivobject_id and indid = 1
    
    if (@f_ind_unique != 1) or (@f_ind_clustered != 1)
    begin
        raiserror(21751, 16, 1, @viewname)
        return 1
    end
    
    --
    -- create an enumeration of all the columns that are part of the view index
    --
    create table #indcoltab(vindexcol int identity, keyname sysname collate database_default not null)
    select @indkey = 1
    while (@indkey <= 16)
    begin
        select @key = index_col( @viewname, 1, @indkey )
        if (@key is null)
            break
        else
            insert into #indcoltab(keyname) values(@key)

        select @indkey = @indkey + 1
    end

    --
    -- We should not have any column participating in this index
    -- that allows NULL if we do
    -- mark the output flag to TRUE
    --
    if exists (select * 
        from sys.columns 
        where object_id = @ivobject_id 
            and is_nullable = 1
            and name in (select keyname from #indcoltab))
    begin
        select @fhasnullcols = 1
    end

    --
    -- all done, cleanup and return
    --
    drop table #indcoltab
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_ivindexhasnullcols] TO [public] AS [dbo]
GO
