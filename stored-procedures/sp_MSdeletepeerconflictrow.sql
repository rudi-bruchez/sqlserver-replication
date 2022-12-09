SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdeletepeerconflictrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdeletepeerconflictrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdeletepeerconflictrow]
	@originator_id [nvarchar](32),
	@origin_datasource [nvarchar](255),
	@tran_id [nvarchar](40),
	@row_id [nvarchar](19),
	@conflict_table [nvarchar](270)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@cmd nvarchar(4000)
                ,@startoffset int
                ,@table	sysname
                ,@schema sysname
				,@whcmd nvarchar(4000) = N'(__$row_id is not null) '


    /*
    **  Security check.  restrict to 'sysadmin' and member of db_owner role
    */ 
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return (1)

    if (@conflict_table is NULL)
    begin
        raiserror(14043, 16, 1, '@conflict_table', 'sp_MSdeletepeerconflictrow')
        return (1)
    end
    --
    -- check if the conflict table is owner qualified
    -- and build the delete string as necessary
    --
    select @table = PARSENAME(@conflict_table, 1),
    		@schema = PARSENAME(@conflict_table, 2)

    begin tran
    save tran tr_deletepeerconflictrow

    if (@row_id != N'%') --delete the corresponding winner or loser record
    begin
		--
	    -- validate row_id to prevent SQL Injection
		-- 
		if(TRY_CONVERT(binary(8), @row_id, 1) is NULL)
			goto UNDO

    	select @cmd = N'delete ' + ISNULL(NULLIF(QUOTENAME(@schema) + N'.', N'.'), N'') + QUOTENAME(@table) + N'
    				    where __$row_id in (
    						select __$row_id
    						from ' + ISNULL(NULLIF(QUOTENAME(@schema) + N'.', N'.'), N'') + QUOTENAME(@table) + N'
    						where __$change_id = ' + @row_id + N'
    						union
    						select __$change_id
    						from ' + ISNULL(NULLIF(QUOTENAME(@schema) + N'.', N'.'), N'') + QUOTENAME(@table) + N'
    						where __$row_id = ' + @row_id + N' and __$change_id is not null)'
    	 execute (@cmd)
    	 if @@error <> 0
    	 	goto UNDO
    end
    		
    select @cmd = 'delete ' + ISNULL(NULLIF(QUOTENAME(@schema) + N'.', N'.'), N'') + QUOTENAME(@table)

    if (@originator_id != N'%')
    begin
          select @whcmd = @whcmd + N' and __$originator_id = ' + QUOTENAME(@originator_id, '''')
    end
    if (@origin_datasource != N'%')
    begin
           select @whcmd = @whcmd + N' and __$origin_datasource = ' + QUOTENAME(@origin_datasource, '''')
    end
    if (@tran_id != N'%')
    begin
           select @whcmd = @whcmd + N' and __$tranid = ' + QUOTENAME(@tran_id, '''')
    end
    if (@row_id != N'%')
    begin
			--
			-- validate row_id to prevent SQL Injection
			-- 
			if(TRY_CONVERT(binary(8), @row_id, 1) is NULL)
				goto UNDO

            select @whcmd = @whcmd + N' and __$row_id = ' + @row_id --delete the specified record: either loser or winner
    end
	select @cmd = @cmd + N' where ' + @whcmd
    execute (@cmd)
    if @@error <> 0
    	 	goto UNDO

    commit tran
    return (0)

UNDO:
   rollback tran tr_deletepeerconflictrow
   commit tran 

   raiserror(21542, 16, 1, @@error, 'sp_MSdeletepeerconflictrow')
   return (1)

end
GO
GRANT EXECUTE ON [sys].[sp_MSdeletepeerconflictrow] TO [public] AS [dbo]
GO
