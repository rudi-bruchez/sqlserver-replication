SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetpeerwinnerrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetpeerwinnerrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetpeerwinnerrow]
	@originator_id [nvarchar](32),
	@row_id [nvarchar](19),
	@conflict_table [nvarchar](270)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int = 0
				,@cmd nvarchar(4000) 
				,@whcmd nvarchar(4000) = N'__$is_winner = 1 '

	select @cmd = N'select ''__$origin_datasource_srvname'' = h.originator_node,  ''__$origin_datasource_db'' = h.originator_db, * from ' + ISNULL(NULLIF(QUOTENAME(PARSENAME(@conflict_table, 2)) + N'.', N'.'), N'') + QUOTENAME(PARSENAME(@conflict_table, 1))
	
    /*
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    --
    -- passed the security check
    --

    if (@originator_id != N'%')
    begin
            select @whcmd = @whcmd + N' and __$originator_id = ' + quotename(@originator_id, '''')
    end

    --
    -- validate row_id to prevent SQL Injection
    --

	if (@row_id != N'%' and TRY_CONVERT(binary(8), @row_id, 1) is NULL)
	begin
	        raiserror('Invalid @row_id in procedure sp_MSgetpeerwinnerrow', 16, 1)
	        return (1)
	end

	if (@row_id != N'%')
    begin
            select @whcmd = @whcmd + N' and ((__$change_id is not null and __$change_id = ' + @row_id
					+ N') or(__$change_id is null and __$row_id in (select __$change_id from ' 
					+ ISNULL(NULLIF(QUOTENAME(PARSENAME(@conflict_table, 2)) + N'.', N'.'), N'') + QUOTENAME(PARSENAME(@conflict_table, 1)) 
					+ N' where __$row_id = ' + @row_id + N')))'
    end
    select @cmd = @cmd + N' c join MSpeer_originatorid_history h on c.__$origin_datasource = h.originator_id where ' + @whcmd

    --
    -- execute the generated select
    --
    execute (@cmd)
    --
    -- all done
    --
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetpeerwinnerrow] TO [public] AS [dbo]
GO
