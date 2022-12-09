SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdategenerations_afterbcp]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdategenerations_afterbcp] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdategenerations_afterbcp]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @guidsrc uniqueidentifier
    declare @guidstr varchar(100)
    declare @pubid_ins uniqueidentifier
    declare @nicknames varbinary(1000)
    declare @art_nick int
    declare @artnick int
    declare @coldate datetime
    declare @subscriber_number int
    declare @genstatus int
    declare @changecount int
    declare @source_gen bigint
    declare @dest_gen bigint
    declare @objid sysname
    declare @cmd nvarchar(4000)
    declare @retcode int
    declare @temp_genhistory_table sysname
    declare @qual_temp_genhistory_table sysname

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1

    select @guidstr = sys.fn_MSguidtostr(@pubid)
    select @temp_genhistory_table = 'MSmerge_genhistory_' + LOWER(@guidstr)
    select @qual_temp_genhistory_table = 'dbo.' + @temp_genhistory_table
    
    select @objid = object_id from sys.objects where name = @temp_genhistory_table
    if @objid is NULL
    begin
        raiserror(20008, 16, -1)
        return 1
    end   

    begin tran
    save tran updategenerations_afterbcp
    -- insert into genhistory, update to contents +tombstone , drop temp table should all be in the same transaction
    -- to avoid the scenario where merge agent fails after inserting into genhistory but before updating contents
    -- tombstone. While retrying merge, bcp would not be re-applied and the same old rows from the temp table
    -- could get reinserted into MSmerge_genhistory (with new generation no, but same guidsrc)

    select @cmd = 'insert into dbo.MSmerge_genhistory (guidsrc, pubid, art_nick, nicknames, coldate, genstatus, changecount, subscriber_number) 
    select guidsrc, pubid, art_nick, nicknames, coldate, genstatus, changecount, subscriber_number from ' + @qual_temp_genhistory_table

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE
        
    select @cmd = 'alter table ' + @qual_temp_genhistory_table + ' add mgh_generation bigint'

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE
        
        -- add clustered index
    select @cmd = 'create unique clustered index c1' + @temp_genhistory_table + ' on ' + @qual_temp_genhistory_table + '(guidsrc)' 

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    select @cmd = 'update ' + @qual_temp_genhistory_table + ' set mgh_generation = mgh.generation 
    from ' + @qual_temp_genhistory_table + ' tgh  
    join dbo.MSmerge_genhistory mgh on mgh.guidsrc = tgh.guidsrc'    
    
    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    select @cmd = 'drop index c1' + @temp_genhistory_table + ' on ' + @qual_temp_genhistory_table 
    
    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE
        
    -- add clustered index
    select @cmd = 'create unique clustered index c2' + @temp_genhistory_table + ' on ' + @qual_temp_genhistory_table + '(generation)' 

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    select @cmd = 'update dbo.MSmerge_contents set generation = tgh.mgh_generation 
    from dbo.MSmerge_contents mc 
    join ' + @qual_temp_genhistory_table + ' tgh on tgh.generation = mc.generation and tgh.art_nick = mc.tablenick'

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    select @cmd = 'update dbo.MSmerge_tombstone set generation = tgh.mgh_generation 
    from dbo.MSmerge_tombstone mt
    join ' + @qual_temp_genhistory_table + ' tgh on tgh.generation = mt.generation and tgh.art_nick = mt.tablenick'

    exec @retcode = sys.sp_executesql @cmd
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    -- drop temp genhistory table
    exec ('drop table ' + @qual_temp_genhistory_table)
    commit tran

    return (0)
FAILURE:  
    if @@trancount>0
    begin
        rollback tran updategenerations_afterbcp
        commit tran
    end
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MSupdategenerations_afterbcp] TO [public] AS [dbo]
GO
