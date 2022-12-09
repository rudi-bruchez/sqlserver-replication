SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetpeerconflictrow]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetpeerconflictrow] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetpeerconflictrow]
	@originator_id [nvarchar](32),
	@origin_datasource [nvarchar](32),
	@tran_id [nvarchar](32),
	@row_id [nvarchar](32),
	@conflict_table [nvarchar](270)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int = 0
			,@cmd nvarchar(4000) 
			,@whcmd nvarchar(4000) = N'where c.__$is_winner = 0 '
	
	select @cmd = N'select w.__$winner_origin_datasource_srvname, w.__$winner_origin_datasource_db, ''__$origin_datasource_srvname'' = h.originator_node,  ''__$origin_datasource_db'' = h.originator_db, c.* from ' 
				+ ISNULL(NULLIF(QUOTENAME(PARSENAME(@conflict_table, 2)) + N'.', N'.'), N'') + QUOTENAME(PARSENAME(@conflict_table, 1))
				+ N' c join MSpeer_originatorid_history h on c.__$origin_datasource = h.originator_id'
				+ N' left join (select distinct ''__$winner_origin_datasource_srvname'' = hw.originator_node, ''__$winner_origin_datasource_db'' = hw.originator_db, cw.__$change_id, cw.__$row_id from '
				+ ISNULL(NULLIF(QUOTENAME(PARSENAME(@conflict_table, 2)) + N'.', N'.'), N'') + QUOTENAME(PARSENAME(@conflict_table, 1))
				+ N' cw join MSpeer_originatorid_history hw on cw.__$origin_datasource = hw.originator_id where cw.__$is_winner = 1) as w on '
				+ N' ((w.__$change_id is not null and w.__$change_id = c.__$row_id) or (w.__$change_id is null and w.__$row_id = c.__$change_id)) '
				
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
    if (@origin_datasource != N'%')
    begin
            select @whcmd = @whcmd + N' and __$origin_datasource = ' + quotename(@origin_datasource, '''')
    end
    if (@tran_id != N'%')
    begin
            select @whcmd = @whcmd + N' and __$tranid = ' + quotename(@tran_id, '''')
    end
    if (@row_id != N'%')
    begin
            select @whcmd = @whcmd + N' and __$row_id = ' + @row_id
    end
    select @cmd = @cmd + @whcmd

    --
    -- execute the generated select
    --
    execute (@cmd)
    --
    -- all done
    --
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetpeerconflictrow] TO [public] AS [dbo]
GO
