SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddinitialschemaarticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddinitialschemaarticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddinitialschemaarticle]
	@name [sysname],
	@destination_object [sysname],
	@destination_owner [sysname],
	@artid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@pre_creation_command [tinyint],
	@status [int],
	@type [tinyint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    
    declare @objid int
    declare @old_objid int
    declare @retcode int
    declare @qualified_name nvarchar(270)

    /*
    ** Security check
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return(1)
    
    if (@artid is NULL)
    begin
        raiserror (14057, 16, -1)
        return 1
    end

    if @destination_owner is null or @destination_owner = ''
    begin
        select @destination_owner = SCHEMA_NAME()
    end

    select @qualified_name = quotename(@destination_owner) + '.' + quotename(@destination_object)

    select @objid = object_id(@qualified_name)
    if @objid IS NULL
    begin 
        raiserror (21543, 16, -1, @qualified_name)
        rollback transaction
       return 1
    end

    select @old_objid = null
    select @old_objid = objid from dbo.sysmergeschemaarticles 
     where artid = @artid
       and pubid = @pubid

    -- Update the objid field of all merge schema articles with the same article id
    update dbo.sysmergeschemaarticles 
        set objid = @objid 
            where artid = @artid

    -- Update the objid field of all transactional schema articles with the same article id or same old objid
    if @old_objid is not null and @objid <> @old_objid
    begin
        if object_id('sysschemaarticles') is not NULL
        begin
            update sysschemaarticles 
               set objid = @objid 
             where objid = @old_objid
        end  
    end

    begin transaction

    if exists (select * from dbo.sysmergeschemaarticles where artid = @artid and pubid = @pubid)
    begin
        

        update dbo.sysmergeschemaarticles
           set name = @name,
               destination_object = @destination_object,
               destination_owner = @destination_owner,
               pre_creation_command = @pre_creation_command,
               status = @status,
               type = @type
         where artid = @artid
           and pubid = @pubid              

        if @@error<>0
        begin
            rollback transaction
            return 1
        end

    end
    else
    begin

        insert dbo.sysmergeschemaarticles
            (name, type, objid, artid, description, pre_creation_command, 
             pubid, status, creation_script, schema_option, destination_object,
             destination_owner)
        values 
            (@name, @type, @objid, @artid, NULL, @pre_creation_command,
             @pubid, @status, NULL, 0x0000000000000000, @destination_object,
             @destination_owner)
        if @@error<>0
        begin
            rollback transaction
            return 1
        end
        
    end

    exec @retcode = dbo.sp_MSmarkschemaobject @destination_object, @destination_owner
    if @@error<>0 or @retcode<>0
    begin
        rollback transaction
        return 1    
    end 

    commit transaction

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSaddinitialschemaarticle] TO [public] AS [dbo]
GO
