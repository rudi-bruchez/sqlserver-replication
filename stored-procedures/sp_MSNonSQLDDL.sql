SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSNonSQLDDL]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSNonSQLDDL] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSNonSQLDDL]
	@qual_source_object [nvarchar](540),
	@pubid [uniqueidentifier],
	@columnName [sysname],
	@schemasubtype [int]
WITH EXECUTE AS CALLER
AS
declare @len            int
    declare @prec            int
    declare @scale int
    declare @typename nvarchar(270)
    declare @objid int
    declare @schemaversion int 
    declare @artname sysname
    declare @schemaguid    uniqueidentifier
    declare @schematype    int
    declare @retcode int
    declare @artid uniqueidentifier
    declare @non_qualified_name nvarchar(255)
    declare @qual_column        nvarchar(255)
    declare @is_null            int
    declare @is_null_string     nvarchar(20)
    declare @schematext    nvarchar(max)
    declare @index_id int
    declare @column_list nvarchar(4000)
    declare @foreign_key_list nvarchar(4000)
    declare @reference_column_list nvarchar(4000)
    declare @column sysname
    declare @parent_column_id int
    declare @foreign_key_constid int
    declare @reference_column_id int
    declare @foreign_key_id int
    declare @foreign_key_column sysname
    declare @reference_column sysname
    declare @colid int
    declare @is_identity bit
    declare @identity_property nvarchar(1000)
    declare @seed_value sql_variant
    declare @increment_value sql_variant
    declare @referenced_object_id int
    declare @constraint_Name sysname
    declare @key_ordinal tinyint
    declare @default_constraint_definition nvarchar(2000)
    declare @default_constraint_name sysname
    declare @column_with_default sysname

    declare @publisher sysname
    declare @publisher_db sysname

    declare @is_not_for_replication bit  
            ,@delete_referential_action tinyint
            ,@update_referential_action tinyint
    
    select @identity_property = NULL
    select @qual_column=QUOTENAME(@columnName)
    select @seed_value=NULL, @increment_value=NULL
    select @objid = object_id(@qual_source_object)        

    --enum of constants
    declare  @schemasubtype_addcolumn int
            ,@schemasubtype_dropcolumn int
            ,@schemasubtype_altercolumn int
            ,@schemasubtype_disabletrigger int
            ,@schemasubtype_enabletrigger int
            ,@schemasubtype_disabletriggerall int
            ,@schemasubtype_enabletriggerall int
            ,@schemasubtype_dropconstraint int
            ,@schemasubtype_enableconstraint int
            ,@schemasubtype_disableconstraint int
            ,@schemasubtype_enableconstraintall int
            ,@schemasubtype_disableconstraintall int
            ,@schemasubtype_addfk int
            ,@schemasubtype_addun int
            ,@schemasubtype_addchk int
            ,@schemasubtype_adddf int
            ,@schemasubtype_addpk int

    select @schemasubtype_addcolumn = 1 					    --N'ADDCOLUMN'
        ,@schemasubtype_dropcolumn =  2 					    --N'DROPCOLUMN'
        ,@schemasubtype_altercolumn = 3 					    --N'ALTERCOLUMN'
        ,@schemasubtype_addpk = 4							    --N'ADDPRIMARYKEY'
        ,@schemasubtype_addun = 5							    --N'ADDUNIQUE'
        ,@schemasubtype_addfk = 6				        --N'ADDREFERENCE'
        ,@schemasubtype_dropconstraint = 7  			        --N'DROPCONSTRAINT'
        ,@schemasubtype_adddf = 8       						--N'ADDDEFAULT'
        ,@schemasubtype_addchk = 9  							--N'ADDCHECK'
        ,@schemasubtype_disabletrigger = 10 				    --N'DISABLETRIGGER'
        ,@schemasubtype_enabletrigger = 11		    		    --N'ENABLETRIGGER'
        ,@schemasubtype_disabletriggerall = 12		            --N'DISABLETRIGGER'
        ,@schemasubtype_enabletriggerall = 13       	        --N'ENABLETRIGGER'
        ,@schemasubtype_enableconstraint = 14   		        --N'ENABLECONSTRAINT'
        ,@schemasubtype_disableconstraint = 15  		        --N'DISABLECONSTRAINT'
        ,@schemasubtype_enableconstraintall = 16    	        --N'ENABLECONSTRAINT'
        ,@schemasubtype_disableconstraintall = 17   	        --N'DISABLECONSTRAINT'


    --don't worry about non-sql if you don't own this publication
    select @publisher=publisher, @publisher_db=publisher_db from dbo.sysmergepublications where pubid=@pubid
    if LOWER(@publisher)<>LOWER(publishingservername()) or @publisher_db<>db_name()
        return(0)
    
    --get non-qualified object name for heter- subscribers to use
    select @non_qualified_name = QUOTENAME(object_name(objid)),
           @artid= artid
        from dbo.sysmergearticles where pubid=@pubid and objid=@objid

    select @schemaversion = schemaversion from dbo.sysmergeschemachange
    
    if (@schemaversion is NULL)
        set @schemaversion = 1
    else
        select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
        
    set @schemaguid = newid()
    set @schematype = 13 /* schema type for ALTER TABLE for non-SQL subscribers*/

    if @schemasubtype=@schemasubtype_dropcolumn    -- drop column
    begin
        select @schematext = N'alter table ' + @non_qualified_name + ' drop column ' + @qual_column
    end
    else if @schemasubtype in (1,3) -- add column and alter column
    begin
        -- need to change code to use sys.columns category view.
        select @typename = case system_type_id when 240 then type_name(user_type_id) else type_name(system_type_id) end, 
        		@len = max_length, @prec = precision,@scale = scale, @is_null=is_nullable
                from sys.columns where name=@columnName and object_id=@objid                
        if @typename='nvarchar' or @typename='nchar' -- a unit of nchar takes 2 bytes 
            select @len = @len/2
        if @is_null = 1
            select @is_null_string = N' NULL '
        else
            select @is_null_string = N' not NULL '

        exec @retcode = sys.sp_MSRecontructType @typename out, @len, @prec, @scale
        if @@error<>0 OR @retcode <>0 
            return (1)

             declare @definition nvarchar(1024)
             set @definition=NULL
             select @definition=definition from sys.computed_columns where name=@columnName and object_id=@objid
            
        select @is_identity=is_identity, @colid=column_id from sys.columns where object_id=@objid and name=@columnName
        if @is_identity = 1
        begin
            select @seed_value=seed_value, @increment_value=increment_value from sys.identity_columns 
                where object_id=@objid and column_id=@colid
            if @seed_value is NULL or @increment_value is NULL
                raiserror(21263, 16, -1, '@seed_value')
            select @identity_property = N'(' + convert(nvarchar, @seed_value) + N',' + convert(nvarchar, @increment_value) + N')'
        end
        if @schemasubtype = @schemasubtype_addcolumn
        begin
            if @definition is null
            begin
                select @schematext = N'alter table ' + @non_qualified_name + ' add ' + @qual_column    + N' ' + @typename + N' ' + @is_null_string
                
                -- does this column have a default?
                select @default_constraint_name = name, @default_constraint_definition = definition
                from sys.default_constraints
                where parent_object_id = @objid
                and parent_column_id = @colid
                and type = 'D'
                
                if @default_constraint_name is not null and @default_constraint_definition is not null
                begin
                    select @schematext = @schematext + N' constraint ' + quotename(@default_constraint_name) +
                        ' default ' + @default_constraint_definition
                end
            end
            else
            begin
               select @schematext = N'alter table ' + @non_qualified_name + ' add ' + @qual_column    + N' as ' + @definition
            end
        end
        else if @schemasubtype = @schemasubtype_altercolumn
            select @schematext = N'alter table ' + @non_qualified_name + ' alter column ' + @qual_column    + N' ' + @typename + N' ' + @is_null_string
        if @is_identity=1 and @identity_property is not NULL
            select @schematext = @schematext + N' identity ' + @identity_property
    end
    else if @schemasubtype = @schemasubtype_addpk  --add primary key
    begin
        if @columnName=N'' or @columnName is NULL
            select @constraint_Name=N'[replication_primary_' + convert(nvarchar(36), newid()) +']'
        else
            select @constraint_Name = @columnName
        select @index_id=index_id from sys.indexes where object_id = @objid and is_primary_key=1
        select @column_list = N' ', @column = NULL, @colid=NULL

        set @key_ordinal=NULL
        select @key_ordinal = min(key_ordinal)
            from sys.index_columns
            where object_id = @objid 
            and index_id=@index_id 
            and key_ordinal>0
                    
        while @key_ordinal is not NULL
        begin
            select @colid = column_id 
                from sys.index_columns 
                where object_id = @objid 
                and index_id=@index_id 
                and key_ordinal=@key_ordinal
        
            select @column = name from sys.columns where object_id=@objid and column_id = @colid
            
            if @column_list = N' '
                select @column_list = @column
            else 
                select @column_list = @column_list + N', ' + @column

            select @key_ordinal = min(key_ordinal)
                from sys.index_columns
                where object_id = @objid 
                and index_id=@index_id 
                and key_ordinal>@key_ordinal
                and key_ordinal>0
        end
        select @schematext = N'alter table ' + @non_qualified_name + N' add constraint ' + @constraint_Name
                    + N' primary key (' + @column_list + N')'
    end
    else if @schemasubtype = @schemasubtype_addun -- add unique constraint
    begin
        if @columnName=N'' or @columnName is NULL
            select @constraint_Name=N'[replication_unique_' + convert(nvarchar(36), newid()) +']'
        else
            select @constraint_Name = @columnName

        select @index_id=index_id from sys.indexes where object_id = @objid and is_unique_constraint =1
        select @column_list = N' ', @column = NULL, @colid=NULL

        set @key_ordinal=NULL
        select @key_ordinal = min(key_ordinal)
            from sys.index_columns
            where object_id = @objid 
            and index_id=@index_id 
            and key_ordinal>0

        while @key_ordinal is not NULL
        begin
            select @colid = column_id 
                from sys.index_columns 
                where object_id = @objid 
                and index_id=@index_id 
                and key_ordinal=@key_ordinal
        
            select @column = name from sys.columns where object_id=@objid and column_id = @colid
            if @column is NULL
                raiserror(14043, 16, 1, '@column', 'sp_MSNonSQLDDL')
            if @column_list = N' '
                select @column_list = @column
            else 
                select @column_list = @column_list + N', ' + @column

            select @key_ordinal = min(key_ordinal)
                from sys.index_columns
                where object_id = @objid 
                and index_id=@index_id 
                and key_ordinal>@key_ordinal
                and key_ordinal>0                
        end
        select @schematext = N'alter table ' + @non_qualified_name + N' add constraint ' + @constraint_Name 
                    + ' unique (' + @column_list + N')'
    end
    else if @schemasubtype=@schemasubtype_addfk --add reference
    begin
        if @columnName=N'' or @columnName is NULL
            select @constraint_Name=N'[replication_foreign_' + convert(nvarchar(36), newid()) + ']'
        else
            select @constraint_Name = @columnName
        select @constraint_Name = QUOTENAME(@constraint_Name)
        select @schematext = N' '
        select @foreign_key_constid = NULL

        --can not use TOP 1 here, as the result won't be NULL when done. Same below
        --@columnName = N'' means that it is a column level foreign key; otherwise, we qualify with constraint name of @columnName

        select @foreign_key_constid = min(constraint_object_id) from sys.foreign_key_columns 
            where parent_object_id=@objid and (@columnName=N'' or @columnName = object_name(constraint_object_id))
        while (@foreign_key_constid is not NULL)
        begin
            select @reference_column_list=N' ', @foreign_key_list=N' ' 
            select @parent_column_id = NULL, @reference_column_id = NULL
            select @parent_column_id = min(parent_column_id) from sys.foreign_key_columns 
                where parent_object_id=@objid and constraint_object_id = @foreign_key_constid
            while (@parent_column_id is not NULL)
            begin
                select @reference_column_id=referenced_column_id, @referenced_object_id=referenced_object_id from sys.foreign_key_columns 
                    where parent_object_id=@objid and constraint_object_id = @foreign_key_constid and parent_column_id=@parent_column_id
                select @reference_column = name from sys.columns where object_id=@referenced_object_id and column_id=@reference_column_id
                select @foreign_key_column=name from sys.columns where object_id=@objid and column_id=@parent_column_id
                if @reference_column_list = N' '
                    select @reference_column_list = @reference_column
                else
                    select @reference_column_list = @reference_column_list + N',' + @reference_column
                if @foreign_key_list = N' '
                    select @foreign_key_list = @foreign_key_column
                else
                    select @foreign_key_list = @foreign_key_list + N',' + @foreign_key_column
                select @parent_column_id = min(parent_column_id) from sys.foreign_key_columns 
                    where parent_object_id=@objid and constraint_object_id = @foreign_key_constid and parent_column_id > @parent_column_id                    
            end
                        
            if @schematext = N' '
                select @schematext = N'alter table ' + @non_qualified_name + N' add constraint ' + @constraint_Name
                    + N' foreign key (' + @foreign_key_list + N') references ' + object_name(@referenced_object_id) + N' (' + @reference_column_list + N' ) '
            else
                select @schematext = @schematext + N', constraint ' + @constraint_Name + 
                    N' foreign key (' + @foreign_key_list + N') references ' +
                        object_name(@referenced_object_id) + N' (' + @reference_column_list + N' ) '

            -- check if we need to add CASCADE attribute
                     select @is_not_for_replication=is_not_for_replication,  
                              @delete_referential_action=delete_referential_action, 
                              @update_referential_action=update_referential_action
                        from sys.foreign_keys
                        where parent_object_id = @objid and name=@columnName

                     if @delete_referential_action in (1,2,3)
                     begin
                        select @schematext = @schematext + N'on delete ' + 
                        case @delete_referential_action
                            when 1 then N'cascade '
                            when 2 then N'set null '
                            when 3 then N'set default '
                        end
                     end
                     
                     if @update_referential_action in (1,2,3)
                     begin
                        select @schematext = @schematext + N'on update ' + 
                        case @update_referential_action
                            when 1 then N'cascade '
                            when 2 then N'set null '
                            when 3 then N'set default '
                        end
                     end

                     if @is_not_for_replication = 1
                     begin
                        select @schematext = @schematext + N'not for replication '
                     end
                    
            select @foreign_key_constid = min(constraint_object_id) from sys.foreign_key_columns 
                where parent_object_id=@objid and (@columnName=N'' or @columnName = object_name(constraint_object_id))
                     and constraint_object_id > @foreign_key_constid
        end
    end
    else if @schemasubtype = @schemasubtype_dropconstraint  -- drop constraint
    begin
        -- removed this for bug 686296
        -- N' if object_id(''' +@qual_column+ N''') is not null ' +
        select @schematext = 
        N'alter table ' + @non_qualified_name + ' drop constraint ' + @qual_column
    end
    else if @schemasubtype = @schemasubtype_adddf -- add default constraint
    begin
        if @columnName=N'' or @columnName is NULL
            select @constraint_Name=N'[replication_default_' + convert(nvarchar(36), newid()) +']'
        else
            select @constraint_Name = @columnName
            
        select @default_constraint_definition = dc.definition, @column_with_default = c.name
        from sys.default_constraints dc join sys.columns c
        on dc.parent_object_id = c.object_id
        and dc.parent_column_id = c.column_id
        and dc.name = @constraint_Name
        
        -- if we added the column for this default in this same ALTER TABLE statement, then we would have 
        -- already posted an ALTER TABLE ADD COLUMN x DEFAULT y - so no need to post a separate ALTER TABLE ADD DEFAULT.
        
        if object_id(N'tempdb..#merge_altertable', 'U') is not null
        begin
			if exists (select * from #merge_altertable where ColumnName = @column_with_default
						and TableName = object_name(@objid)
						and DDLsubtype = N'ADDCOLUMN')
				return 0
        end
            
        select @schematext = N'alter table ' + @non_qualified_name + N' add constraint ' + quotename(@constraint_Name)
                    + N' default ' + @default_constraint_definition + N' for ' + quotename(@column_with_default)
    end
    else
        select @schematext = N' ' --place-holder for alter column
            
    exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext, @schemasubtype 
    if @@ERROR<>0 or @retcode<>0
    begin
        
        raiserror(21533, 16, -1)                            
        return (1)
    end
return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSNonSQLDDL] TO [public] AS [dbo]
GO
