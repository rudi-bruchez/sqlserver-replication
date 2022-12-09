SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdroparticleconstraints]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdroparticleconstraints] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdroparticleconstraints]
	@destination_object [sysname],
	@destination_owner [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode      int,
            @objid        int,
            @constid      int,
            @drop_command nvarchar(4000),
            @qualified_tablename nvarchar(540),
            @publish_bit  int,
            @mergepublish_bit int

    
    select @retcode             = 0,
           @objid               = null,
           @constid             = null,
           @drop_command        = null,
           @qualified_tablename = null,
           @publish_bit         = 1,
           @mergepublish_bit    = 128

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@error<>0
        return 1

    -- Get object id of the target table
    select @objid = object_id 
      from sys.objects
     where name = @destination_object
       and (schema_name(schema_id) = @destination_owner 
            or @destination_owner is null 
            or @destination_owner = N'')

    -- If the object is not at the subscriber, there isn't anything we 
    -- can(or need to)  do
    if @objid is null 
        return 0

    select @qualified_tablename = 
            N'['+replace(@destination_object,N']',N']]')+N']'

    if @destination_owner is not null and @destination_owner<>N''
    begin
        select @qualified_tablename = 
            N'['+replace(@destination_owner,N']',N']]')+N'].'+@qualified_tablename
    end

    -- Skip constraint dropping for republished article
    if exists (select * 
                 from sys.tables 
                where object_id = @objid
                  and ((is_published = 1) or
                       (is_merge_published = 1)))
    begin
        return 0
    end

    declare hConst cursor local fast_forward for
     select constid 
       from sysconstraints 
      where id = @objid
      order by convert(int, objectproperty(constid,'IsForeignKey')) desc
    if @@error<>0
        return 1

    open hConst
    if @@error<>0
        return 1
    
    fetch hConst into @constid 
    while (@@fetch_status<>-1)
    begin
    
        if objectproperty(@constid,N'IsUniqueCnst') = 1 or
           objectproperty(@constid,N'IsPrimaryKey') = 1 or
           objectproperty(@constid,N'IsCheckCnst') = 1 or
           objectproperty(@constid,N'IsForeignKey') = 1
        begin
            select @drop_command = 
                N'alter table '+@qualified_tablename+' drop constraint '+ QUOTENAME(object_name(@constid))
            exec(@drop_command)
            if @@error <> 0
                return 1
        end
        fetch hConst into @constid        
    end
    close hConst
    deallocate hConst

    return @retcode

end
GO
GRANT EXECUTE ON [sys].[sp_MSdroparticleconstraints] TO [public] AS [dbo]
GO
