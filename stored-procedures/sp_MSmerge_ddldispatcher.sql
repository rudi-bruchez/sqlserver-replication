SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_ddldispatcher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_ddldispatcher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_ddldispatcher]
	@EventData [xml],
	@procmapid [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

	declare @retcode int

    EXEC @retcode = sys.sp_MSreplcheck_publish_withddladmin @skip_error_print = 1		--the user should either dbo or ddladmin
    IF @@ERROR <> 0 or @retcode <> 0
    begin
        raiserror (21050, 16, -1)
        return (1)
    end

    -- validate the procmapid
    if @procmapid not in (1,2,3,4)
    begin
        raiserror(15021, 16, -1, '@procmapid')
        goto FAILURE
    end

    declare @debug_print bit 
    if object_id('MSrepl_debug_DDL') is not null
        set @debug_print = 1
    else
        set @debug_print = 0


    declare @object_name sysname
                ,@object_owner sysname
                ,@qual_object_name nvarchar(512) --qualified 3-part-name            
                ,@objid    int
                ,@objecttype varchar(32)
                ,@encrypted nvarchar(32)
                ,@pass_through_scripts nvarchar(max)
                ,@eventDoc int
                ,@db_name sysname
                ,@targetobject nvarchar(51)

    
            
    set @targetobject=N''
    -- parse event data
    select @object_name  = event_instance.value('ObjectName[1]', 'sysname')
        ,@object_owner = event_instance.value('SchemaName[1]', 'sysname')
        ,@objecttype = event_instance.value('ObjectType[1]', 'varchar(32)')
        ,@encrypted = event_instance.value('(TSQLCommand/SetOptions/@ENCRYPTED)[1]', 'nvarchar(32)')
        ,@pass_through_scripts = event_instance.value('(TSQLCommand/CommandText)[1]', 'nvarchar(max)')
        ,@targetobject = event_instance.value('TargetObjectName[1]', 'nvarchar(512)')
    FROM       @EventData.nodes('/EVENT_INSTANCE') as R(event_instance)


	if @debug_print = 1
		select 'stage' = 'xmlnoderefs : '
					, '@object_name' = @object_name
					, '@object_owner' = @object_owner 
					, '@objecttype' = @objecttype 
					, '@encrypted' = @encrypted 
					, '@pass_through_scripts' = @pass_through_scripts
					, '@targetobject' = @targetobject

    -- If the object being manipulated is a database level trigger that is owned by replication, raise error
    if exists (select * from sys.triggers where name = @object_name and parent_class = 0 and @objecttype = 'TRIGGER' and @object_name in (N'MSmerge_tr_altertable', N'MSmerge_tr_alterview', N'MSmerge_tr_alterschemaonly', N'MSmerge_tr_altertrigger'))
    begin
        raiserror(21598, 16, 1)        
        goto FAILURE
    end
    
    -- If the object being manipulated is a database level trigger that is not owned by replication, return immediately
    if exists (select * from sys.triggers where name = @object_name and parent_class = 0 and @objecttype = 'TRIGGER' and @object_name not in (N'MSmerge_tr_altertable', N'MSmerge_tr_alterview', N'MSmerge_tr_alterschemaonly', N'MSmerge_tr_altertrigger'))
        return 0
    
    
    select @qual_object_name = QUOTENAME(@object_owner) + N'.' + QUOTENAME(@object_name)
    select @objid = object_id(@qual_object_name)
    select @db_name=db_name()

	if @debug_print = 1
		select 'stage' = 'quotename : '
					, '@qual_object_name' = @qual_object_name
					, '@objid' = @objid
					, '@dbname' = @db_name
	
    if @objid is NULL
    begin
        -- add error message
        goto FAILURE
    end

    --can not alter to 'with encrypted' if object is published
    --return immediately if object is not published
    if UPPER(@encrypted) = N'TRUE'
    begin    
        if object_id('dbo.sysmergeextendedarticlesview') is not null
        begin
            if (UPPER(@objecttype) != 'TRIGGER' and 
                exists (SELECT * FROM dbo.sysmergeextendedarticlesview WHERE objid = @objid) 
                )
            begin 
                raiserror(21815, 16, 1, @qual_object_name)        
                goto FAILURE
            end   
			else if  (UPPER(@objecttype) = 'TRIGGER' and object_id('dbo.sysmergearticles') is not null)
			begin
				if exists (select * from sysmergearticles a join sys.objects o on a.objid = o.parent_object_id where o.object_id = @objid)
				begin 
					raiserror(21815, 16, 1, @qual_object_name)        
					goto FAILURE
				end
				else
					return 0		--If trigger isn't published, return       
			end
			else
				return 0			--If non-trigger object isn't published, return
		 end
    end

    /*
    -- remove 3 part naming
    exec sys.sp_replgetparsedddlcmd
            @pass_through_scripts output
            , N'ALTER'
            ,@objecttype
            ,@db_name
            ,@object_owner
            ,@object_name
            ,@targetobject
    */            
    select @pass_through_scripts = sys.fn_replgetparsedddlcmd(@pass_through_scripts
														,N'ALTER'
														,@objecttype
														,@db_name
														,@object_owner
														,@object_name
														,@targetobject)

	-- sys.fn_replgetparsedddlcmd will return empty string if DDL contains 
	-- syntax that we don't currently handle (after Katmai DDL
	-- improvement)
	if @pass_through_scripts = N''
		return 0

    --if merge replication is not enabled for this db, or object is not published, don''t do anything
    --refer to sp_MScreate_mergesystables for sys tables
    if object_id('dbo.sysmergearticles') is not null
    begin
        declare @proc_name sysname

	    --  Security Check
	    EXEC @retcode = sys.sp_MSreplcheck_publish_withddladmin @skip_error_print = 1
	    IF @@ERROR <> 0 or @retcode <> 0
			goto FAILURE

        select @proc_name = case 
                    when (@procmapid = 1) then 'sys.sp_MSmerge_altertable' 
                    when (@procmapid = 2) then 'sys.sp_MSmerge_alterview' 
                    when (@procmapid = 3) then 'sys.sp_MSmerge_alterschemaonly' 
                    when (@procmapid = 4) then 'sys.sp_MSmerge_altertrigger' 
                    end
        if (@objecttype != 'TRIGGER' and exists (SELECT * FROM dbo.sysmergeextendedarticlesview WHERE objid = @objid)) 
        begin
			if (@procmapid = 1 or @procmapid = 4 )
			begin
				exec @retcode = @proc_name @qual_object_name, @objid, @pass_through_scripts 
				if (@@error <> 0 or @retcode <> 0)
					goto FAILURE
			end
			else if (@procmapid = 2 or @procmapid = 3)
			begin
				exec @retcode = @proc_name @qual_object_name, @objid, @pass_through_scripts, @objecttype
				if (@@error <> 0 or @retcode <> 0)
					goto FAILURE
			end
		end	
        if (@objecttype = 'TRIGGER' and object_id('dbo.sysmergearticles') is not null)
        begin
            if exists (select * from sysmergearticles a join sys.objects o on a.objid = o.parent_object_id where o.object_id = @objid)
	        begin
					exec @retcode = @proc_name @qual_object_name, @objid, @pass_through_scripts, @targetobject 
					if (@@error <> 0 or @retcode <> 0)
						goto FAILURE
			end
		end	
    end
    return 0

FAILURE:
    -- this rolls back the implicit transaction
    -- all changes within this transaction is rolled back.
    ROLLBACK TRANSACTION
    raiserror(21530, 16, -1)
    return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_ddldispatcher] TO [public] AS [dbo]
GO
