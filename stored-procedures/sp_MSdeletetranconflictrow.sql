SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdeletetranconflictrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdeletetranconflictrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdeletetranconflictrow]
	@tran_id [sysname],
	@row_id [sysname],
	@conflict_table [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@cmd nvarchar(4000)
                ,@startoffset int
                ,@table	sysname
                ,@schema sysname

    /*
    **  Security check.  restrict to 'sysadmin' and member of db_owner role
    */ 
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return (1)

    if (@conflict_table is NULL)
    begin
        raiserror(14043, 16, 1, '@conflict_table', 'sp_MSdeletetranconflictrow')
        return (1)
    end
    --
    -- check if the conflict table is owner qualified
    -- and build the delete string as necessary
    --
    select @table = PARSENAME(@conflict_table, 1),
    		@schema = PARSENAME(@conflict_table, 2)
    		
    select @cmd = 'delete ' + ISNULL(NULLIF(QUOTENAME(@schema) + N'.', N'.'), N'') + QUOTENAME(@table)
            + ' where tranid = ' + QUOTENAME(@tran_id, '''')

    if (@row_id != N'%')
    begin
        select @cmd = @cmd +
        ' and qcfttabrowid = ' + QUOTENAME(@row_id, '''')
    end
    
    execute (@cmd)
end
GO
GRANT EXECUTE ON [sys].[sp_MSdeletetranconflictrow] TO [public] AS [dbo]
GO
