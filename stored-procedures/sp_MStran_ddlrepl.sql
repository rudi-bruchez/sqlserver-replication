SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MStran_ddlrepl]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MStran_ddlrepl] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MStran_ddlrepl]
	@EventData [xml],
	@procmapid [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
	declare @retcode int

    -- validate the procmapid
    if @procmapid not in (1,2,3,4,5)
    begin
        raiserror(15021, 16, -1, '@procmapid')
        goto FAILURE
    end
    --if transactional replication is not enabled for this db, don't do anything
    if (sys.fn_MSrepl_istranpublished (db_name(),0) != 1)
        return 0
	
    declare @object_name sysname
                ,@object_owner sysname
                ,@qual_object_name nvarchar(512) --qualified 2-part-name			
                ,@objid	int
                ,@objecttype varchar(32)
                ,@encrypted nvarchar(32)
                ,@pass_through_scripts nvarchar(max)
                ,@eventDoc int
                ,@dbname sysname
                ,@targetobject nvarchar(51)
                ,@debug_print bit
		
	if object_id('MSrepl_debug_DDL') is not null
		set @debug_print = 1
	else
		set @debug_print = 0

    set	@targetobject = N''
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
    if exists (select * from sys.triggers where name = @object_name and parent_class = 0 and @objecttype = 'TRIGGER' and @object_name in (N'tr_MStran_altertable', N'tr_MStran_alterview', N'tr_MStran_alterschemaonly', N'tr_MStran_altertrigger', N'tr_MStran_droptable'))
    begin
        raiserror(21598, 16, 1)        
        goto FAILURE
    end
    
    -- If the object being manipulated is a database level trigger that is not owned by replication, return immediately
    if exists (select * from sys.triggers where name = @object_name and parent_class = 0 and @objecttype = 'TRIGGER' and @object_name not in (N'tr_MStran_altertable', N'tr_MStran_alterview', N'tr_MStran_alterschemaonly', N'tr_MStran_altertrigger', N'tr_MStran_droptable'))
        return 0

    select @qual_object_name = quotename(@object_owner) + N'.' + quotename(@object_name)
    select @objid = object_id(@qual_object_name)
    select @dbname = db_name()

	if @debug_print = 1
		select 'stage' = 'quotename : '
					, '@qual_object_name' = @qual_object_name
					, '@objid' = @objid
					, '@dbname' = @dbname

    --can not alter to 'with encrypted' if object is published
    --return immediately if object is not published
    if UPPER(@encrypted) = N'TRUE'
    begin	
        if (UPPER(@objecttype) != 'TRIGGER' and 
            exists (SELECT * FROM dbo.sysextendedarticlesview WHERE objid = @objid) 
        or UPPER(@objecttype) = 'TRIGGER' and 
            exists (select * from sysarticles a join sys.objects o on a.objid = o.parent_object_id
                                    where o.object_id = @objid and cast (a.schema_option as int) & 256 = 256) )
        begin 
            raiserror(21815, 16, 1, @qual_object_name)		
            goto FAILURE
        end
        else
            return 0
    end
	
    --stored procedures published as "proc execution" article cannot contain
    --table value parameters (Note: proc exec articles are only listed in 
    --dbo.sysarticles
    if exists (select * 
                 from sys.parameters sp 
           inner join dbo.sysarticles a
                   on sp.object_id = a.objid
                where sp.system_type_id = 243
                  and sp.object_id = @objid
                  and a.type in (0x08, 0x18))
    begin
        raiserror(25023,16,-1)
        goto FAILURE
    end
    select @pass_through_scripts = sys.fn_replgetparsedddlcmd(@pass_through_scripts
														,N'ALTER'
														,@objecttype
														,@dbname
														,@object_owner
														,@object_name
														,@targetobject)
    where @procmapid in (1,2,3,4) /* for ALTER only */

	if @debug_print = 1
		select 'stage' = 'sys.fn_replgetparsedddlcmd output : '
				, '@pass_through_scripts' = @pass_through_scripts

	-- sys.fn_replgetparsedddlcmd will return empty string if DDL contains 
	-- syntax that we don't currently handle (after Katmai DDL
	-- improvement)
	--It will also handle a duplicate trigger in the case of "alter table switch"
	if @pass_through_scripts = N''
		return 0

    -- deal with alternate dest table/owner for alter table inside sp_MStran_altertable
    if UPPER(@objecttype) != N'TABLE' and UPPER(@objecttype) != N'TRIGGER' and @procmapid in (1,2,3,4) /* for ALTER only */
    begin
        select @pass_through_scripts = N'ALTER ' + @objecttype + N' '
    								+ @qual_object_name + N' '
    								+ @pass_through_scripts
    end
																																																						
    --if object is not published, don't do anything, unless SWITCH is the following keyword
    if (UPPER(@objecttype) != 'TRIGGER' and exists (SELECT * FROM dbo.sysextendedarticlesview WHERE objid = @objid) 
    	or UPPER(@objecttype) = 'TRIGGER' and exists (select * from sysarticles a join sys.objects o on a.objid = o.parent_object_id
    					where o.object_id = @objid ) 
		or UPPER(@objecttype) = N'TABLE' and LEFT(@pass_through_scripts, LEN(N'SWITCH')) = N'SWITCH'
		or UPPER(@objecttype) = N'TABLE' and @procmapid = 5 /* DROP TABLE */)
    begin
        declare @proc_name sysname

        if @procmapid in (1,2,3,4) /* need this check for ALTER only. for DROP it was checked before this trigger */
        begin
            --  Security Check
            EXEC @retcode = sys.sp_MSreplcheck_publish
            IF @@ERROR <> 0 or @retcode <> 0
                goto FAILURE
        end

        select @proc_name = case 
                    when (@procmapid = 1) then 'sys.sp_MStran_altertable' 
                    when (@procmapid = 2) then 'sys.sp_MStran_alterview' 
                    when (@procmapid = 3) then 'sys.sp_MStran_alterschemaonly' 
                    when (@procmapid = 4) then 'sys.sp_MStran_altertrigger' 
                    when (@procmapid = 5) then 'sys.sp_MStran_droptable' 
                    end

        exec @retcode = @proc_name @qual_object_name, @objid, @pass_through_scripts, @targetobject 
		if @retcode <>0 or @@ERROR<>0
			goto FAILURE
    end
    return 0
FAILURE:
    rollback tran 
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MStran_ddlrepl] TO [public] AS [dbo]
GO
