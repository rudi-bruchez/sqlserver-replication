SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpcreatebeforetable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpcreatebeforetable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpcreatebeforetable]
	@objid [int],
	@newname [sysname]
WITH EXECUTE AS CALLER
AS
declare @command nvarchar(1000)
    declare @retcode int
    declare @include int
    declare @tablenick int
    declare @colname nvarchar(140)
    declare @typename nvarchar(258)
    declare @base_typename nvarchar(140)
    declare @schname     nvarchar(140)
    declare @system_type_id int
    declare @colid smallint
    declare @colidstr nvarchar(5)
    declare @len smallint
    declare @prec smallint
    declare @scale int
    declare @isnullable tinyint
    declare @cMaxIndexLength int

    set @cMaxIndexLength= 900  -- max index column size in SQL 2000

    set nocount on
    
    -- Security check: dbo and sysadmin only
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        select 'a' = 'raiserror (''Error creating before image table'' , 16, -1)'
        return (1)
    end

    select @tablenick = max(nickname) from dbo.sysmergearticles where objid = @objid
    if @tablenick is null 
    begin
        select 'a' = 'raiserror (''Error creating before image table'' , 16, -1)'
        return (1)
    end
        
    -- create temp table to select the command text out of
    declare @tempcmd table (phase int NOT NULL, step int identity NOT NULL, cmdtext nvarchar(4000) collate database_default null)

    set @command = 'create table dbo.' + quotename(@newname) + '('
    insert into @tempcmd (phase, cmdtext) values (1, @command)
    
    -- Loop over the columns and see which ones we include

    declare col_cursor CURSOR LOCAL FAST_FORWARD 
    for select  C.name,  type_name(C.user_type_id), type_name(C.system_type_id),
                    case when S.name<>'sys' and S.name<>'dbo'
                            then QUOTENAME(S.name)+'.' else '' end,
                   C.system_type_id, C.max_length, C.precision, C.scale, C.is_nullable, C.column_id 
    from sys.columns C
            INNER JOIN sys.types T ON C.user_type_id = T.user_type_id
            INNER JOIN sys.schemas S ON T.schema_id = S.schema_id                   
    where C.object_id = @objid and C.is_computed <> 1 and C.user_type_id <> type_id('timestamp') order by C.column_id
    FOR READ ONLY
        
    open col_cursor
    fetch next from col_cursor into @colname, @typename, @base_typename, @schname, @system_type_id, @len, @prec, @scale, @isnullable, @colid
    while (@@fetch_status <> -1)
    begin
        set @include = 0
        
        if columnproperty( @objid, @colname , 'isrowguidcol')=1
        begin
            set @include = 1
        end
        else
        begin
            -- does updating this column change membership in a partial replica? 
            if exists (select * from dbo.sysmergearticles 
                where objid = @objid and sys.fn_MSisfilteredcolumn(subset_filterclause, @colname, @objid) = 1)
                set @include = 1
            else if exists (select * from dbo.sysmergesubsetfilters
                where art_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @colname, @objid) = 1)
                set @include = 1
            else if exists (select * from dbo.sysmergesubsetfilters
                where join_nickname = @tablenick and sys.fn_MSisfilteredcolumn(join_filterclause, @colname, @objid) = 1)
                set @include = 1
        end
        -- If we want this column, map its type and insert a row to temp table
        if @include = 1
        begin
            if ((@base_typename='nvarchar' or @base_typename='nchar') and @len <> -1) -- a unit of nchar takes 2 bytes
                set @len = @len/2
            exec @retcode = sys.sp_MSmaptype @typename out, @len, @prec, @scale         
            if @@ERROR<>0 or @retcode<>0 goto Failure
            if (sys.fn_IsTypeBlob(@system_type_id, @len) = 0)
            begin
                select @colname = N'[' + replace(@colname, N']', N']]') + N']'
    
                if @isnullable = 1
                    set @command = @colname + ' ' + @schname + @typename + ' NULL, '
                else
                    set @command = @colname + ' ' + @schname + @typename + ' NOT NULL, '
                
                -- Insert the part of create table command for this column
                insert into @tempcmd (phase, cmdtext) values (1, @command)

                -- Insert a create index command if column is not too long
                if (@len <= @cMaxIndexLength)
                begin
                    set @colidstr =convert(nvarchar(4), @colid)
                    set @command = 'create index ' + quotename(@newname + '_' + @colidstr) + ' on ' + quotename(@newname) + ' (' + @colname + ') '
                    insert into @tempcmd (phase, cmdtext) values (2, @command)
                end
            end
        end
        /* Repeat the loop with next column */
        fetch next from col_cursor into @colname, @typename, @base_typename, @schname,  @system_type_id, @len, @prec, @scale, @isnullable, @colid
    end

    close col_cursor
    deallocate col_cursor

    -- Insert last column, generation
    set @command = 'generation bigint NOT NULL, system_delete bit default(0))
        '
    insert into @tempcmd (phase, cmdtext) values (1, @command)
    set @command = 'create clustered index ' + quotename(@newname + '_gen') + ' on ' + quotename(@newname) + '(generation) 
        '
    insert into @tempcmd (phase, cmdtext) values (2, @command)
        
    select cmdtext from @tempcmd order by phase, step
    --drop table @tempcmd

    return(0)
Failure:
    close col_cursor
    deallocate col_cursor
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MShelpcreatebeforetable] TO [public] AS [dbo]
GO
