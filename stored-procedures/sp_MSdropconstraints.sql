SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropconstraints]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropconstraints] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropconstraints]
	@table [sysname],
	@owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @const_name nvarchar(258)
    declare @objid int
    declare @retcode int
    declare @qualified_tablename   nvarchar(517)
    declare @quoted_tablename   nvarchar(270)
    declare @quoted_ownername   nvarchar(270)
    
    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)

    select @quoted_tablename = quotename(@table)
    
    if @owner is not NULL
    begin
        set @quoted_ownername = QUOTENAME(@owner)
        set @qualified_tablename= @quoted_ownername + '.' + @quoted_tablename
    end
    else
        set @qualified_tablename= @quoted_tablename
    
    set @objid = object_id(@qualified_tablename)
    if @objid is null
    begin
        if @owner is null
        begin
            select @objid = object_id from sys.objects 
                where name=@quoted_tablename
        end
        else
        begin
            select @objid = object_id from sys.objects 
                where name=@quoted_tablename and schema_name(schema_id)=@quoted_ownername
        end
    end
    if @objid is NULL
        return (1)

    select @const_name = QUOTENAME(object_name(object_id)) from 
        sys.foreign_keys where parent_object_id = @objid

    while @const_name is not null
    begin
        exec ('alter table ' + @qualified_tablename +
            ' drop constraint ' + @const_name)
        if @@ERROR <> 0
            return (1)
        set @const_name = NULL
        select @const_name = QUOTENAME(object_name(object_id)) from 
            sys.foreign_keys where parent_object_id = @objid
    end

    return (0)      
GO
GRANT EXECUTE ON [sys].[sp_MSdropconstraints] TO [public] AS [dbo]
GO
