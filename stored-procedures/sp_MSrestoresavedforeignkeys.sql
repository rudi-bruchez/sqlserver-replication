SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrestoresavedforeignkeys]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrestoresavedforeignkeys] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrestoresavedforeignkeys]
	@program_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode                    int,
            @constraint_name            sysname,
            @parent_name                sysname,
            @parent_schema              sysname,
            @referenced_object_name     sysname,
            @referenced_object_schema   sysname,
            @is_disabled                bit,
            @is_not_for_replication     bit,
            @is_not_trusted             bit,
            @delete_referential_action  tinyint,
            @update_referential_action  tinyint,
            @transaction_opened         bit,
            @cursor_allocated           bit,
            @cursor_opened              bit,
            @command                    nvarchar(4000),
            @referencing_object_id      int,
            @referenced_object_id       int

    select @retcode = 0,
           @transaction_opened = 0,
           @cursor_allocated = 0,
           @cursor_opened = 0


    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return 1

    -- There is nothing to do if any of the foreign key restoration 
    -- system tables are missing
    if object_id('dbo.MSsavedforeignkeys', 'U') is null or
       object_id('dbo.MSsavedforeignkeycolumns', 'U') is null or
       object_id('dbo.MSsavedforeignkeyextendedproperties', 'U') is null
    begin
        return 0
    end

    if @program_name is null
    begin
        select @program_name = program_name 
          from sys.sysprocesses
         where spid = @@spid
    end

    begin transaction 
    save transaction sp_MSrestoresavedforeignkeys
    set @transaction_opened = 1
    
    declare hForeignKeys cursor local 
        for
    select constraint_name, 
           parent_schema,
           parent_name,
           referenced_object_schema,
           referenced_object_name,
           is_disabled,
           is_not_for_replication,
           is_not_trusted,
           delete_referential_action,
           update_referential_action
      from dbo.MSsavedforeignkeys    
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
    set @cursor_allocated = 1

    open hForeignKeys
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
    set @cursor_allocated = 1

    fetch hForeignKeys into @constraint_name, @parent_schema, @parent_name,
        @referenced_object_schema, @referenced_object_name, @is_disabled,
        @is_not_for_replication, @is_not_trusted, @delete_referential_action, 
        @update_referential_action

    while (@@fetch_status <> -1)
    begin

        -- Check if foreign key can be restored

        -- Is the foreign key already present?
        if object_id(quotename(@parent_schema) + N'.' + quotename(@constraint_name), 'F') is not null goto SkipForeignKey
    
        -- Is the referencing table present?
        select @referencing_object_id = object_id(quotename(@parent_schema) + N'.' + quotename(@parent_name), 'U') 
        if @referencing_object_id is null goto SkipForeignKey

        -- Is the referenced table present?
        select @referenced_object_id =  object_id(quotename(@referenced_object_schema) + N'.' + quotename(@referenced_object_name), 'U') 
        if @referenced_object_id is null goto SkipForeignKey

        -- Are all the referencing columns present?
        if exists (select *  
                     from dbo.MSsavedforeignkeycolumns
                    where program_name = @program_name
                      and constraint_name = @constraint_name
                      and referencing_column_name not in
                            (select name collate DATABASE_DEFAULT
                               from sys.columns
                              where object_id = @referencing_object_id))
            goto SkipForeignKey

        -- Are all the referenced columns present?
        if exists (select *
                     from dbo.MSsavedforeignkeycolumns
                    where program_name = @program_name
                      and constraint_name = @constraint_name
                      and referenced_column_name not in
                            (select name collate DATABASE_DEFAULT
                               from sys.columns
                              where object_id = @referenced_object_id))
            goto SkipForeignKey
 
        -- Is there a candidate referenced index key present?
        if not exists (select key_constraints.name 
                         from sys.index_columns index_columns
                   inner join sys.indexes indexes
                           on index_columns.index_id = indexes.index_id
                          and index_columns.object_id = indexes.object_id
                   inner join sys.key_constraints key_constraints
                           on indexes.name = key_constraints.name
                          and schema_name(key_constraints.schema_id) = @referenced_object_schema
                        where indexes.object_id = @referenced_object_id
                          and index_columns.column_id <> 0
                          and indexes.index_id not in
                                -- Indexes with columns that do not match
                                -- those saved in dbo.MSsavedforeignkeycolumns
                                (select index_columns.index_id
                                   from sys.index_columns index_columns
                             inner join sys.columns columns
                                     on index_columns.object_id = columns.object_id
                                    and index_columns.column_id = columns.column_id
                              left join 
                                    (select referenced_column_name, constraint_column_id
                                       from dbo.MSsavedforeignkeycolumns
                                      where program_name = @program_name
                                        and constraint_name = @constraint_name
                                        and parent_schema = @parent_schema) foreignkeycolumns (referenced_column_name, constraint_column_id)
                                     on columns.name collate DATABASE_DEFAULT = foreignkeycolumns.referenced_column_name
                                    and index_columns.key_ordinal = foreignkeycolumns.constraint_column_id
                                  where index_columns.object_id = @referenced_object_id
                                    and index_columns.column_id <> 0
                                    and foreignkeycolumns.referenced_column_name is null)
                         -- The the number of columns in the index matches 
                         -- that in the foreign key
                     group by key_constraints.name
                    having count(key_constraints.name) = 
                        (select count(*) 
                           from dbo.MSsavedforeignkeycolumns 
                          where program_name = @program_name
                            and constraint_name = @constraint_name
                            and parent_schema = @parent_schema))
            goto SkipForeignKey

        select @command = N'execute sys.sp_MSscriptforeignkeyrestore @program_name = N''' + replace(@program_name, N'''', N'''''') +
            N''', @constraint_name = N''' + replace(@constraint_name, N'''', N'''''') +
            N''', @parent_schema = N''' + replace(@parent_schema, N'''', N'''''') +
            N''', @parent_name = N''' + replace(@parent_name, N'''', N'''''') +
            N''', @referenced_object_schema = N''' + replace(@referenced_object_schema, N'''', N'''''') +
            N''', @referenced_object_name = N''' + replace(@referenced_object_name, N'''', N'''''') +
            N''', @is_not_for_replication = ' + convert(nvarchar(2), @is_not_for_replication) +
            N', @is_not_trusted = ' + convert(nvarchar(2), @is_not_trusted) + 
            N', @delete_referential_action = ' + convert(nvarchar(3), @delete_referential_action) +
            N', @update_referential_action = ' + convert(nvarchar(3), @update_referential_action)
        if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end

        execute @retcode = sys.sp_execresultset @cmd = @command
        if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end

        -- Disable foreign key if it was originally disabled
        if @is_disabled = 1
        begin
            set @command = N'alter table ' + quotename(@parent_schema) + N'.' + quotename(@parent_name) + ' nocheck constraint ' + quotename(@constraint_name)
            execute (@command)
            if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
        end

        -- Restore extended properties defined on foreign key
        execute @retcode = sys.sp_MSrestoresavedforeignkeyextendedproperties 
            @program_name = @program_name,
            @constraint_name = @constraint_name,
            @parent_schema = @parent_schema,
            @parent_name = @parent_name
        if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
 
SkipForeignKey:

        fetch hForeignKeys into @constraint_name, @parent_schema, @parent_name,
            @referenced_object_schema, @referenced_object_name, @is_disabled,
            @is_not_for_replication, @is_not_trusted, @delete_referential_action, 
            @update_referential_action
    end

    close hForeignKeys
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
    set @cursor_opened = 0

    deallocate hForeignKeys
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end
    set @cursor_allocated = 0

    -- Cleanup foreign key tables now that everything is restored
    delete from dbo.MSsavedforeignkeys where program_name = @program_name
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end

    delete from dbo.MSsavedforeignkeycolumns where program_name = @program_name
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end

    delete from dbo.MSsavedforeignkeyextendedproperties where program_name = @program_name
    if @@error <> 0 or @retcode <> 0 begin set @retcode = 1 goto Failure end

    commit transaction
    set @transaction_opened = 0

Failure:
    if @cursor_opened = 1
    begin
        close hForeignKeys
    end    

    if @cursor_allocated = 1
    begin
        deallocate hForeignKeys
    end

    if @transaction_opened = 1
    begin
        rollback transaction sp_MSrestoresavedforeignkeys
        commit transaction
    end
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSrestoresavedforeignkeys] TO [public] AS [dbo]
GO
