SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddguidcolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddguidcolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddguidcolumn]
	@source_owner [sysname],
	@source_table [sysname]
WITH EXECUTE AS CALLER
AS
declare @rowguidcol         sysname
    declare @quoted_rowguidcol     nvarchar(258)
    declare @id                    int
    declare @id_str                nvarchar(100)
    declare @qualified_name        nvarchar(517)
    declare @columns            varbinary(128)
    declare @retcode            int
    declare @colid                int
    declare @pubid                uniqueidentifier
    declare @default_bit        int    
    declare @default_function    nvarchar(100)
    declare @default_function_like    nvarchar(100)
    declare @qualified_rowguidcol_name	nvarchar(776)

    set nocount on

    -- Security check
    if 1 <> is_member('db_owner')
    begin
        raiserror(15247,-1,-1)
        return 1
    end

    select @qualified_name = QUOTENAME(@source_owner) + '.' + QUOTENAME(@source_table)
    select @id = object_id(@qualified_name)
    
    if exists (select * from dbo.sysmergearticles sma join dbo.sysmergepublications smp
                on sma.pubid = smp.pubid
                where sma.objid = @id
                and smp.backward_comp_level < 90
                and (sys.fn_MSmerge_islocalpubid(smp.pubid) = 1))
    begin
        select @default_function = N' newid() '
        select @default_function_like = '%newid%'
    end
    else
    begin
        select @default_function = N' newsequentialid() '
        select @default_function_like = '%newsequentialid%'
    end
    
    /* Alter the source table to add a rowguid column */
    begin tran
    save tran sp_MSaddguidcolumn
    exec sys.sp_MSunmarkreplinfo @object=@source_table, @owner=@source_owner
    if @@ERROR <>0 goto UNDO

    if (ObjectProperty(object_id(@qualified_name), 'tablehasrowguidcol')<>1)
    begin
        -- we have to use guid as objid is reused in different db's and hence potential collision in naming when replicated
        DECLARE @guidid uniqueidentifier
        SET @guidid = newid()
        exec @retcode=sys.sp_MSguidtostr @guidid, @id_str out
        if @retcode<>0 or @@ERROR<>0 
            goto UNDO
        exec sys.sp_MSuniquecolname @table_name=@qualified_name, @base_colname='rowguid', @unique_colname=@rowguidcol output
        set @quoted_rowguidcol= quotename(@rowguidcol)

        exec ('alter table ' + @qualified_name + ' add ' + @quoted_rowguidcol 
                + ' uniqueidentifier ROWGUIDCOL not null constraint MSmerge_df_rowguid_' 
                + @id_str + ' default ' + @default_function)
        if @@ERROR<>0 goto UNDO
    end
    else --add default constraint on the rowguidcol, if it does not have one for its own.
    begin
        declare @quoted_constraint_name nvarchar(258)
        declare @const_id int, @bound_default_id int
        
        select @default_bit= 5
        select @colid=column_id, @rowguidcol = name, @bound_default_id = default_object_id
        from sys.columns 
        where object_id=@id and is_rowguidcol=1
    
		set @quoted_rowguidcol= quotename(@rowguidcol)
		    
        if @bound_default_id is not null
        begin
			-- Is this a default constraint or a bound default ?
			-- If bound default, unbind.
			if exists (select * from sys.objects where object_id = @bound_default_id
						and parent_object_id = 0)
			begin
				-- unbind
				select @qualified_rowguidcol_name = @qualified_name + N'.' + @quoted_rowguidcol
				exec @retcode = sys.sp_unbindefault @qualified_rowguidcol_name
				IF @@ERROR <> 0 or @retcode <> 0
                    goto UNDO
			end
        end
               
        select @quoted_constraint_name = quotename(name), @const_id = object_id 
        from sys.default_constraints 
        where parent_object_id = @id and parent_column_id = @colid
    
        if @quoted_constraint_name is not null
        begin
            if not exists (select 1 from sys.default_constraints where object_id = @const_id and definition like @default_function_like)
            begin
                EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=1
                IF @@ERROR <> 0 or @retcode <> 0
                    goto UNDO
                   
                -- drop and recreate. This is our way of going back and forth between newid() and newsequentialid()
                -- depending on publication compat level.
                exec('alter table ' + @qualified_name 
                    + ' drop constraint ' + @quoted_constraint_name)
                if @@ERROR<>0 goto UNDO
                
                exec('alter table ' + @qualified_name 
                    + ' add constraint ' + @quoted_constraint_name + 
                    ' default ' + @default_function + ' for ' + @quoted_rowguidcol)
                if @@ERROR<>0 goto UNDO
                
                EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0
                IF @@ERROR <> 0 or @retcode <> 0
                    goto UNDO
            end
        end
        else
        begin
            select @id_str = convert(nvarchar(100),@id)
            if @id_str is NULL
                goto UNDO
                            
            exec('alter table ' + @qualified_name 
                + ' add constraint MSmerge_default_constraint_for_rowguidcol_of_' 
                + @id_str + ' default ' + @default_function + ' for ' + @quoted_rowguidcol)
            if @@ERROR<>0 goto UNDO
                            
        end
    end
    exec sys.sp_MSunmarkreplinfo @object=@source_table, @owner=@source_owner, @type = 1
    if @@ERROR<>0 goto UNDO
    
    commit tran
    return (0)
UNDO:
    EXEC @retcode = sys.sp_MSsetcontext_bypasswholeddleventbit @onoff=0
    rollback tran sp_MSaddguidcolumn
    commit tran
    return (1)    
GO
GRANT EXECUTE ON [sys].[sp_MSaddguidcolumn] TO [public] AS [dbo]
GO
