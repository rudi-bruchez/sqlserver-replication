SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscriptforeignkeyrestore]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscriptforeignkeyrestore] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscriptforeignkeyrestore]
	@program_name [sysname],
	@constraint_name [sysname],
	@parent_schema [sysname],
	@parent_name [sysname],
	@referenced_object_schema [sysname],
	@referenced_object_name [sysname],
	@is_not_for_replication [bit],
	@is_not_trusted [bit],
	@delete_referential_action [tinyint],
	@update_referential_action [tinyint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    declare @retcode int
    declare @number_of_key_columns int

    declare @script table (line_number int identity primary key, line nvarchar(4000))

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return 1

    select @number_of_key_columns = count(*)
      from dbo.MSsavedforeignkeycolumns
     where program_name = @program_name
       and constraint_name = @constraint_name
       and parent_schema = @parent_schema 

    insert into @script (line) values (N'alter table ' + quotename(@parent_schema) + N'.' + quotename(@parent_name))
    if @is_not_trusted = 1
    begin
        insert into @script (line) values (N'with nocheck')    
    end
    insert into @script (line) values (N'add constraint ' + quotename(@constraint_name) + N' foreign key (' )

    insert into @script (line) 
        select quotename(referencing_column_name)
          from dbo.MSsavedforeignkeycolumns
         where program_name = @program_name
           and constraint_name = @constraint_name
           and parent_schema = @parent_schema
           and constraint_column_id = 1

    insert into @script (line)
        select N', ' + quotename(referencing_column_name)
          from dbo.MSsavedforeignkeycolumns
         where program_name = @program_name
           and constraint_name = @constraint_name
           and parent_schema = @parent_schema
           and constraint_column_id > 1
        order by constraint_column_id asc

    insert into @script (line) values (N') references ' + quotename(@referenced_object_schema) + N'.' + quotename(@referenced_object_name) + N' (')

    insert into @script (line) 
        select quotename(referenced_column_name)
          from dbo.MSsavedforeignkeycolumns
         where program_name = @program_name
           and constraint_name = @constraint_name
           and parent_schema = @parent_schema
           and constraint_column_id = 1

    insert into @script (line)
        select N', ' + quotename(referenced_column_name)
          from dbo.MSsavedforeignkeycolumns
         where program_name = @program_name
           and constraint_name = @constraint_name
           and parent_schema = @parent_schema
           and constraint_column_id > 1
        order by constraint_column_id asc

    insert into @script (line)
    select N') on delete ' + 
        case @delete_referential_action 
            when 1 then N'cascade '
            when 2 then N'set null '
            when 3 then N'set default '
            else N'no action '
        end +
        'on update ' +
        case @update_referential_action
            when 1 then N'cascade '
            when 2 then N'set null '
            when 3 then N'set default '
            else N'no action '
        end +
        case when @is_not_for_replication = 1 then N'not for replication'
             else N''
        end

    select line from @script order by line_number asc    

end
GO
GRANT EXECUTE ON [sys].[sp_MSscriptforeignkeyrestore] TO [public] AS [dbo]
GO
