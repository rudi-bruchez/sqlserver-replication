SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_getpkfkrelation]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_getpkfkrelation] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_getpkfkrelation]
	@filtered_table [nvarchar](400),
	@joined_table [nvarchar](400)
WITH EXECUTE AS CALLER
AS
declare @pk_fk_relationships table (filtered_table_column sysname, joined_table_column sysname)
    
    declare @basecol    sysname
    , @joincol    sysname
    , @basecolid   int
    , @joincolid   int
    , @keycnt        int
    , @base_columns    varbinary(128)
    , @join_columns    varbinary(128)
    , @keyindex    int
    , @retcode    smallint
    , @dri_rowcount int
    , @constid int
    , @base_objid int
    , @join_objid int
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    select @base_objid = object_id(@filtered_table), @join_objid = object_id(@joined_table)
        
    select @constid = object_id, 
           @keycnt = (select count(*) from sys.foreign_key_columns k where k.constraint_object_id = f.object_id)
        from sys.foreign_keys f 
        where f.parent_object_id = @base_objid and f.referenced_object_id = @join_objid
    
    select @dri_rowcount = @@rowcount
          
    /* Loop over keys */
    
    set @keyindex = 1
        
    while @keyindex <= @keycnt
    begin
        /* Get the column names */
        
        /* also pass in vertical partitioning binary to excluded columns that are not in the current partition */
        /*
        exec sys.sp_MSindexcolfrombin @base_objid, @keyindex, @basekeys, @basecol output, NULL
        if @@ERROR<>0 return (1)
        exec sys.sp_MSindexcolfrombin @join_objid, @keyindex, @joinkeys, @joincol output, NULL
        if @@ERROR<>0 return (1)
        */
        select @basecolid = parent_column_id, @joincolid = referenced_column_id 
            from sys.foreign_keys f, sys.foreign_key_columns k 
            where f.parent_object_id = @base_objid and 
                  f.referenced_object_id = @join_objid and 
                  k.constraint_object_id = f.object_id and
                  k.constraint_column_id = @keyindex
                      
        select @basecol = name from sys.columns where object_id = @base_objid and column_id = @basecolid
        select @joincol = name from sys.columns where object_id = @join_objid and column_id = @joincolid        
        
        if @basecol is not NULL and @joincol is not NULL
        begin
            select @basecol = quotename(@basecol), @joincol = quotename(@joincol)
        
            insert into @pk_fk_relationships (filtered_table_column, joined_table_column)
                values (@basecol, @joincol)
        end
            
        /* move on to the next key */
        set @keyindex = @keyindex + 1
    end
    
    select * from @pk_fk_relationships

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_getpkfkrelation] TO [public] AS [dbo]
GO
