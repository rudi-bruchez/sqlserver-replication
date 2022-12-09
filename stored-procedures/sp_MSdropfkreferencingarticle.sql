SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropfkreferencingarticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropfkreferencingarticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropfkreferencingarticle]
	@destination_object_name [sysname],
	@destination_owner_name [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on 
    declare @fk_name sysname,
            @drop_command nvarchar(4000),
            @parent_id int,
            @retcode int,
            @robject_name sysname,
            @robject_schema sysname,
            @transaction_opened bit,
            @cursor_allocated bit,
            @cursor_opened bit,
            @timestamp datetime,
            @program_name sysname,
            @is_disabled bit,
            @is_not_for_replication bit,
            @is_not_trusted bit,
            @delete_referential_action tinyint,
            @update_referential_action tinyint,
            @referenced_object_id int

    select @retcode = 0,
           @transaction_opened = 0,
           @cursor_allocated = 0,
           @timestamp = getdate()

    select @program_name = program_name from sys.sysprocesses where spid = @@spid

    -- Security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return 1    

    if @destination_owner_name is null
    begin
        -- Use default schema of the current user for the destination object
        -- schema if one is not explicitly specified.
        select @destination_owner_name = schema_name()
    end

    select @referenced_object_id = object_id(quotename(@destination_owner_name) + N'.' + quotename(@destination_object_name))

    if @referenced_object_id is null return

    if object_id('dbo.MSsavedforeignkeys', 'U') is null
    begin
        create table dbo.MSsavedforeignkeys
        (
            
            program_name                sysname not null,
            constraint_name             sysname not null,
            parent_schema               sysname not null,
            parent_name                 sysname not null,
            referenced_object_schema    sysname not null,
            referenced_object_name      sysname not null,
            is_disabled                 bit not null,
            is_not_for_replication      bit not null,
            is_not_trusted              bit not null,
            delete_referential_action   tinyint not null,
            update_referential_action   tinyint not null,
            timestamp                   datetime not null         
        )
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        create clustered index ci_MSsavedforeignkeys
            on dbo.MSsavedforeignkeys(program_name, constraint_name, parent_schema)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
        
        create nonclustered index nci_MSsavedforeignkeys_timestamp
            on dbo.MSsavedforeignkeys(timestamp)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        exec @retcode = dbo.sp_MS_marksystemobject 'dbo.MSsavedforeignkeys'
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    end


    if object_id('dbo.MSsavedforeignkeycolumns', 'U') is null
    begin
        create table dbo.MSsavedforeignkeycolumns
        (
            program_name                sysname not null,
            constraint_name             sysname not null,
            parent_schema               sysname not null,
            constraint_column_id        int not null,
            referencing_column_name     sysname not null,
            referenced_column_name      sysname not null,
            timestamp                   datetime not null
        )
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        create clustered index ci_MSsavedforeignkeycolumns
            on dbo.MSsavedforeignkeycolumns(program_name, constraint_name, parent_schema, constraint_column_id)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
        create nonclustered index nci_MSsavedforeignkeycolumns_timestamp
            on dbo.MSsavedforeignkeycolumns(timestamp)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        exec @retcode = dbo.sp_MS_marksystemobject 'dbo.MSsavedforeignkeycolumns'
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    end   
    
    if object_id('dbo.MSsavedforeignkeyextendedproperties', 'U') is null
    begin
        create table dbo.MSsavedforeignkeyextendedproperties
        (
            program_name                sysname not null,
            constraint_name             sysname not null,
            parent_schema               sysname not null,
            property_name               sysname,
            property_value              sql_variant,
            timestamp                   datetime not null
        )
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        create clustered index ci_MSsavedforeignkeyextendedproperties
            on dbo.MSsavedforeignkeyextendedproperties(program_name, constraint_name, parent_schema) 
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

        create nonclustered index nci_MSsavedforeignkeyextendedproperties_timestamp
            on dbo.MSsavedforeignkeyextendedproperties(timestamp)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
        exec @retcode = dbo.sp_MS_marksystemobject 'dbo.MSsavedforeignkeyextendedproperties'
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

    end

    begin transaction
    save transaction sp_MSdropfkreferencingarticle
    set @transaction_opened = 1

    -- Remove stale foreign key entries
    -- Globally remove anything that are more than 15 days old
    -- Remove anything for the calling program more than 3 days old
    delete dbo.MSsavedforeignkeys where timestamp < dateadd(day, -15, @timestamp)
    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    delete dbo.MSsavedforeignkeycolumns where timestamp < dateadd(day, -15, @timestamp)
    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    delete dbo.MSsavedforeignkeys where program_name = @program_name and timestamp < dateadd(day, -3, @timestamp)
    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    delete dbo.MSsavedforeignkeycolumns where program_name = @program_name and timestamp < dateadd(day, -3, @timestamp)
    if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    
    declare hForeignKeys cursor local fast_forward
    for 
        select name, parent_object_id, is_disabled, is_not_for_replication, is_not_trusted, delete_referential_action, update_referential_action 
          from sys.foreign_keys
        where referenced_object_id = @referenced_object_id 
    set @cursor_allocated = 1

    open hForeignKeys
    set @cursor_opened = 1

    fetch hForeignKeys into @fk_name, @parent_id, @is_disabled, @is_not_for_replication, @is_not_trusted, @delete_referential_action, @update_referential_action
    
    while (@@fetch_status <> -1)
    begin
        select @robject_name = name, @robject_schema = schema_name(schema_id)
          from sys.objects 
         where object_id = @parent_id
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 

        insert into dbo.MSsavedforeignkeys 
            (
                program_name,
                constraint_name,
                parent_schema,
                parent_name,
                referenced_object_schema,
                referenced_object_name,
                is_disabled,
                is_not_for_replication,
                is_not_trusted,
                delete_referential_action,
                update_referential_action,
                timestamp
            )
        values
            (
                @program_name,
                @fk_name,
                @robject_schema,
                @robject_name,
                @destination_owner_name,
                @destination_object_name,
                @is_disabled,
                @is_not_for_replication,
                @is_not_trusted,
                @delete_referential_action,
                @update_referential_action,
                @timestamp
            ) 
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 
        insert into dbo.MSsavedforeignkeycolumns
            (
                program_name,
                constraint_name,
                parent_schema,
                constraint_column_id,
                referencing_column_name,
                referenced_column_name,
                timestamp
            )
        select @program_name,
               @fk_name,
               @robject_schema,
               foreign_key_columns.constraint_column_id,
               referencing_columns.name,
               referenced_columns.name,
               @timestamp
          from sys.foreign_key_columns foreign_key_columns
    inner join sys.columns referencing_columns
            on foreign_key_columns.parent_column_id = referencing_columns.column_id and referencing_columns.object_id = @parent_id
    inner join sys.columns referenced_columns
            on foreign_key_columns.referenced_column_id = referenced_columns.column_id and referenced_columns.object_id = @referenced_object_id
         where foreign_key_columns.constraint_object_id = object_id(quotename(@robject_schema) + N'.' + quotename(@fk_name), 'F')
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 

        insert into dbo.MSsavedforeignkeyextendedproperties
            (
                program_name,
                constraint_name,
                parent_schema,
                property_name,
                property_value,
                timestamp
            )
        select @program_name,
               @fk_name,
               @robject_schema,
               name,
               value,
               @timestamp
          from fn_listextendedproperty(default, 'schema', @robject_schema, 'table', @robject_name, 'constraint', @fk_name)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 
        select @drop_command = N'alter table ' +
               quotename(@robject_schema) + N'.' +
               quotename(@robject_name) + 
               N' drop constraint ' + quotename(@fk_name)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 
        exec(@drop_command)
        if @@error <> 0 or @retcode <> 0 begin select @retcode = 1 goto Failure end 

        fetch hForeignKeys into @fk_name, @parent_id, @is_disabled, @is_not_for_replication, @is_not_trusted, @delete_referential_action, @update_referential_action
    end

    close hForeignKeys
    set @cursor_opened = 0

    deallocate hForeignKeys
    set @cursor_allocated = 0

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
        rollback transaction sp_MSdropfkreferencingarticle
        commit transaction
    end
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSdropfkreferencingarticle] TO [public] AS [dbo]
GO
