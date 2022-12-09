SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_mergereplcommand]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_mergereplcommand] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_mergereplcommand]
	@publication [sysname],
	@article [sysname],
	@schematype [int],
	@schematext [nvarchar](2000),
	@tablename [sysname]
WITH EXECUTE AS CALLER
AS
declare @schemaguid         uniqueidentifier
    declare @schemaversion      int
    declare @retcode            int
    declare @pubid              uniqueidentifier
    declare @artid              uniqueidentifier
    declare @objid  int
    
    /*
    ** Publish permission check
    */
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    if @publication IS NULL
    BEGIN
        RAISERROR (14003, 16, -1)
        RETURN (1)
    END

    select @pubid = pubid FROM dbo.sysmergepublications WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    select @artid = artid, @objid = objid FROM dbo.sysmergeextendedarticlesview WHERE name = @article and pubid = @pubid
    /* 
    ** For certain system tables that are bcped out such as MSmerge_contents 
    ** and dbo.MSmerge_tombstone use the article name as sys.objects.name and get
    ** sys.objects.object_id as the artid
    */
    if (@artid IS NULL) AND (@schematype <> 7)
    begin
        declare @binguid binary(16)
        set @binguid = OBJECT_ID(@article)
        set @artid = convert(uniqueidentifier, @binguid)
    end
    else if @tablename is not NULL and (@schematype <> 7)
    begin
        declare @binguid1 binary(8)
        declare @binguid2 binary(8)
        set @binguid1 = convert(binary(8),@objid)
        set @binguid2 = convert(binary(8),OBJECT_ID(@tablename))
        if @binguid2 is NULL
            set @artid = convert(uniqueidentifier, @binguid1)
        else
            set @artid = convert(uniqueidentifier, @binguid1+@binguid2)
    end

    /*
    ** When schematype is 89 SCHEMA_TYPE_CLR_USER_DEFINED_DATA_TYPE the article name is
    ** 		the user_type_id of the udt in string format. 
    ** When schematype is 91 SCHEMA_TYPE_PARTITIONSCHEME the article name is 
    ** 		the function_id of the partition_scheme
    ** When schematype is 92 SCHEMA_TYPE_PARTITIONFUNCTION the article name is 
    ** 		the function_id of the partition_scheme
    **Convert it to guid and use it as artid to
    ** identify the schema change.
    */

    if (@schematype in (88, 89, 90, 91, 92, 93, 96, 31, 105)) and (@article is not NULL)
    begin
        select @artid=convert(uniqueidentifier, convert(binary(16), @article))
    end

    /* now decide if we should insert a new schema change row or update an existing one. 0-insert, 1-update */
    declare @UPDATE_SCHEMACHANGE int     

    if exists (select * from dbo.sysmergeschemachange
            where pubid = @pubid 
            AND artid = @artid
            AND ((schematype = @schematype AND schematype <> 31) -- we need to insert new schema change for CREATE SCHEMA 
                    OR (@schematype in (3,4) and schematype in (3,4))  -- SCHEMA_TYPE_NATIVEBCP or SCHEMA_TYPE_CHARACTERBCP
                    OR (@schematype in (80,81) and schematype in (80,81))  -- SCHEMA_TYPE_SYSTABLE_NATIVE_BCP_90 or SCHEMA_TYPE_SYSTABLE_CHAR_BC_90
                    OR (@schematype in (82,83) and schematype in (82,83))  -- SCHEMA_TYPE_SYSTABLE_NATIVE_BCP_90_FORGLOBALONLY or SCHEMA_TYPE_SYSTABLE_CHAR_BC_90_FORGLOBALONLY
                    OR (@schematype in (84,85) and schematype in (84,85))  -- SCHEMA_TYPE_SYSTABLE_NATIVE_BCP_90_FORLIGHTWEIGHT or SCHEMA_TYPE_SYSTABLE_CHAR_BC_90_FORLIGHTWEIGHT
                    OR (@schematype in (131,132) and schematype in (131,132))  -- SCHEMA_TYPE_DYNAMICNATIVEBCP or SCHEMA_TYPE_DYNAMICCHARBCP
                    OR (@schematype in (208,209) and schematype in (208,209))  -- SCHEMA_TYPE_DYNAMIC_SYSTABLE_NATIVE_BCP_90 or SCHEMA_TYPE_DYNAMIC_SYSTABLE_CHAR_BCP_90
                    OR (@schematype in (210,211) and schematype in (210,211))  -- SCHEMA_TYPE_DYNAMIC_SYSTABLE_NATIVE_BCP_90_FORGLOBALONLY or SCHEMA_TYPE_DYNAMIC_SYSTABLE_CHAR_BCP_90_FORGLOBALONLY
                    OR (@schematype in (212,213) and schematype in (212,213))))  -- SCHEMA_TYPE_DYNAMIC_SYSTABLE_NATIVE_BCP_90_FORLIGHTWEIGHT or SCHEMA_TYPE_DYNAMIC_SYSTABLE_CHAR_BCP_90_FORLIGHTWEIGHT
    begin
        set @UPDATE_SCHEMACHANGE = 1 /*common case to update a row */
    end
    else if exists (select * from dbo.sysmergeschemachange
            where pubid = @pubid 
            AND artid = @artid
            AND schematype = @schematype 
            AND schematype = 31
            AND schematext = @schematext)
    begin
        set @UPDATE_SCHEMACHANGE = 2  /*only insert a CREATE SCHEMA row if the schema text is different from the existing one for the article */
    end
    else
    begin
        set @UPDATE_SCHEMACHANGE = 0; /*common case to insert a new row*/
    end

   if(@UPDATE_SCHEMACHANGE=1 or @UPDATE_SCHEMACHANGE=2 )
   begin
        /* Select the existing schema guid */
        select @schemaversion = schemaversion, @schemaguid = schemaguid from dbo.sysmergeschemachange
            where pubid = @pubid 
            AND artid = @artid
            AND (schematype = @schematype
                  OR (@schematype in (3,4) and schematype in (3,4)) 
                  OR (@schematype in (80,81) and schematype in (80,81))
                  OR (@schematype in (82,83) and schematype in (82,83))
                  OR (@schematype in (84,85) and schematype in (84,85))
                  OR (@schematype in (131,132) and schematype in (131,132))
                  OR (@schematype in (208,209) and schematype in (208,209))
                  OR (@schematype in (210,211) and schematype in (210,211))
                  OR (@schematype in (212,213) and schematype in (212,213)))
                   
        /* For directory commands, delete the previous directory before the update */
        if (@schematype = 7)
        begin

            /* Also remove the alternate directory command, pre/post 
            ** commands, snapshot header commands, and 
            ** dynsnap validation command from the 
            ** dbo.sysmergeschemachange table
            */                     
            delete dbo.sysmergeschemachange
             where pubid = @pubid 
               AND schematype in (25, 40, 45, 50, 51, 52, 53, 54, 55, 56, 57, 58, 71)

        end

        /*
        ** Update the schema change version
        */
        if(@UPDATE_SCHEMACHANGE=1)
        begin
            exec @retcode = sys.sp_MSupdateschemachange @pubid, @artid, @schemaversion, 
                @schemaguid, @schematype, @schematext
        end
        else if (@UPDATE_SCHEMACHANGE=2)
        begin
            /* don't update the schematext here, and we need the schematext value to find the correct row to update */
            exec @retcode = sys.sp_MSupdateschemachange @pubid, @artid, @schemaversion, 
                @schemaguid, @schematype, @schematext, 0
        end                
        
        if @@error <> 0 or @retcode <> 0
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end
    else        
    begin
        /* Insert the schema change */
        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange

        /* update the schema version and schemaguid in dbo.sysmergesubscriptions */      
        declare @subid       uniqueidentifier
        declare @sysmergesub_schemaversion  int
        declare @sysmergesub_schemaguid     uniqueidentifier

        select  @subid = subid from dbo.sysmergesubscriptions 
            where UPPER(subscriber_server) collate database_default = UPPER(publishingservername()) collate database_default
                and db_name = DB_NAME() and pubid = @pubid

        select @sysmergesub_schemaversion = schemaversion, @sysmergesub_schemaguid = schemaguid
                from dbo.sysmergesubscriptions where subid = @subid 

        /* 
        ** If the schema version matches the dbo.sysmergesubscriptions.schemaversion and the schema_type = 52 (snapshot trailer), 
        ** then reuse the dbo.sysmergesubscriptions.schema_guid. Otherwise generate a new guid.
        */
        if @sysmergesub_schemaversion is NOT NULL and @schemaversion = @sysmergesub_schemaversion and @schematype = 52
        begin
            set @schemaguid = @sysmergesub_schemaguid
        end
        else
        begin
            set @schemaguid = newid()
        end
            
        exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, 
            @schemaguid, @schematype, @schematext
        if @@error <> 0 or @retcode <> 0
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end

    if (@schematype = 7)
    begin
        update dbo.sysmergesubscriptions set last_validated=getdate() where pubid=@pubid and subid=@pubid
        IF @@ERROR <> 0
        begin
            RAISERROR(20054 , 16, -1)
            RETURN (1)
        end
    end     

        /*
        ** If we are inserting the snapshot trailer then we are done with the snapshot commands.
        ** At this time remove all entries of type 
        ** SCHEMA_TYPE_CLR_USER_DEFINED_DATA_TYPE, 
        ** SCHEMA_TYPE_PARTITIONSCHEME
        ** SCHEMA_TYPE_PARTITIONFUNCTION
        ** that are still marked inactive.
        */
        
    if (@schematype = 52)
    begin
        delete from dbo.sysmergeschemachange where pubid=@pubid and schematype in (88, 89, 90, 91, 92, 93, 96, 105) and schemastatus = 0
        IF @@ERROR <> 0
        begin
            RETURN (1)
        end
    end     

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSadd_mergereplcommand] TO [public] AS [dbo]
GO
