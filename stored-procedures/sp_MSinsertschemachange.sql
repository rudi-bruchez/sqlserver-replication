SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinsertschemachange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinsertschemachange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinsertschemachange]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@schemaversion [int],
	@schemaguid [uniqueidentifier],
	@schematype [int],
	@schematext [nvarchar](max),
	@schemasubtype [int],
	@update_schemaversion [tinyint]
WITH EXECUTE AS CALLER
AS
declare @retcode            int
    declare @constraintname     sysname 
    declare @owner              sysname
    declare @tablename          sysname
    declare @qualname           nvarchar(270)
    declare @objid              int
    declare @alter_table_type   int
    declare @subid    uniqueidentifier
    
    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    select @alter_table_type = 11
    
    /* Parameter validation */
    if (@schemaversion is null)
        begin
        RAISERROR(14043, 16, -1, '@schemaversion', 'sp_MSinsertschemachange')
        return (1)
        end

    /*
    ** Special case: for push subscription, reinit-with-upload, we do not want to cleanup subscriber side
    ** cause we need to upload; however we still need to apply alter-table. To avoid duplicate key insert
    ** failure, we no-OP this insert of alter-table schema.
    */
    if @schematype=@alter_table_type and exists 
        (select * from dbo.sysmergeschemachange where pubid=@pubid and schemaversion=@schemaversion)
        return (1)

    begin transaction tran_sp_MSinsertschemachange
	save transaction tran_sp_MSinsertschemachange
        
    if not exists (select * from dbo.sysmergeschemachange with (HOLDLOCK TABLOCKX)
                where pubid=@pubid and artid=@artid and 
                      schemaversion=@schemaversion and schemaguid = @schemaguid and 
                      schematype = @schematype)
    begin
        insert into dbo.sysmergeschemachange with (HOLDLOCK TABLOCKX)
        (pubid, artid, schemaversion, schemaguid, schematype, schematext, schemasubtype)
                 values (@pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext, @schemasubtype) 
    end
    else
    begin
        update dbo.sysmergeschemachange with (HOLDLOCK TABLOCKX)
        	set schematext = @schematext 
        	where pubid=@pubid and artid=@artid and 
                      schemaversion=@schemaversion and schemaguid = @schemaguid and 
                      schematype = @schematype
    end
    if @@error <> 0     
    begin
        rollback transaction tran_sp_MSinsertschemachange
	    commit transaction
        RAISERROR(21305 , 16, -1)
        return (1)
    end
    
    /* update the schema version and schemaguid in dbo.sysmergesubscriptions - The following servername is used as a publishing server name */      
    if @update_schemaversion = 1
    begin
        select @subid = subid from dbo.sysmergesubscriptions 
            where UPPER(subscriber_server) collate database_default = UPPER(publishingservername()) collate database_default
               and db_name = DB_NAME() and pubid = @pubid

        update dbo.sysmergesubscriptions set schemaversion = @schemaversion, schemaguid = @schemaguid
            where subid = @subid and (schemaversion<@schemaversion or schemaversion is NULL)
        if @@error <> 0     
            begin
            rollback transaction tran_sp_MSinsertschemachange
    	    commit transaction
            RAISERROR(21305 , 16, -1)
            return (1)
        end
    end    
    commit transaction
    return (0)      
GO
GRANT EXECUTE ON [sys].[sp_MSinsertschemachange] TO [public] AS [dbo]
GO
