SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetreplicainfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetreplicainfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetreplicainfo]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@datasource_type [int],
	@server_name [sysname],
	@db_name [sysname],
	@datasource_path [nvarchar](255),
	@replnick [varbinary](6),
	@schemaversion [int],
	@subid [uniqueidentifier],
	@compatlevel [int],
	@partition_id [int],
	@replica_version [int],
	@activate_subscription [bit]
WITH EXECUTE AS CALLER
AS
declare @pubid      uniqueidentifier
    declare @repid      uniqueidentifier
    declare @retcode    int
    declare @maxlevel   int

    /*
    ** ODBC Issue - trim names
    */
    select @publisher_db = RTRIM(@publisher_db)
    select @db_name = RTRIM(@db_name)

    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    /* 
    ** Security Check and publication validation
    */
    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, @publisher_db, @publisher, @pubid output
    if @retcode <> 0 or @@error <> 0
        return 1
    
    if (@server_name is NULL)
        SET @server_name = publishingservername()

    exec sys.sp_MSget_server_portinfo 
        @name = @server_name, 
        @srvname = @server_name OUTPUT

    if (@db_name is NULL)
        set @db_name = db_name()

    SELECT @repid = subid FROM dbo.sysmergesubscriptions
        WHERE UPPER(subscriber_server) collate database_default = UPPER(@server_name) collate database_default
            and db_name = @db_name and pubid = @pubid
    if @repid is NULL
    begin
        RAISERROR(20021, 16, -1)
        return (1)
    end

    update dbo.MSmerge_replinfo set validation_level = 0, resync_gen=-1 where repid=@repid

    if 1=@activate_subscription
    begin
        update dbo.sysmergesubscriptions set status=1 where subid=@repid and (status=5 or status=0)
    end

    if @schemaversion is not null and
       -- sp_MSsetreplicainfo is also called to update the subscriber replica info that is stored
       -- at the publisher. If the subscriber has a schemaversion of -1, it means that the subscriber
       -- wants to reinit. However, this should not be set at the publisher, because this would
       -- falsely indicate that the publisher wants to reinit.
       (
            @schemaversion <> -1 or
            UPPER(publishingservername()) collate database_default <> UPPER(@publisher) collate database_default or
            db_name() <> @publisher_db
       )
    begin
        update dbo.sysmergesubscriptions set schemaversion = @schemaversion where subid = @repid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end
        
    if @subid is not null and @subid <> @repid
    begin
        /* Fix the repid for pull subscribers before we copy around global replica rows */
        update dbo.MSmerge_replinfo set repid = @subid where repid = @repid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
        update dbo.sysmergesubscriptions set subid = @subid where subid = @repid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end
        
    if @replnick IS NOT NULL        
    begin
        /* If this nickname isn't already assigned, reset it */
        /* Replnick in 80 was int and in 90 is binary(6). The proc
           does a implicit conversion from int to varbinary(6) but we still
           need to reverse the binary value to get a corresponding 90 replnick */
        if @compatlevel < 90
            set @replnick= cast(reverse(substring(@replnick,1,4)) as binary(4))+ 0x0000  
        else
        begin
        	-- Fix the replnick to 4 bytes + 0x0000 if the compatlevel is less than 80.
        	-- This prevents us from having real 6 byte replnicks when there are 80 subscribers
        	-- Having real 6 byte replnicks in mixed mode can cause non-convergence because the 
        	-- lineages can not be converted from 90 to 80 and back to 90 without losing last two bytes of replnick.
		    select @maxlevel= sys.fn_MSgetmaxbackcompatlevel()

		    if @maxlevel <= 80
				set @replnick = substring(@replnick,1,4) + 0x0000        	
        end
        if exists (select * from dbo.sysmergesubscriptions
                where replnickname = @replnick and subid = subid and 
                    ((UPPER(subscriber_server) collate database_default <> UPPER(@server_name) collate database_default) or db_name <> @db_name))
            return (0)
        update dbo.sysmergesubscriptions set replnickname = @replnick where subid = @subid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end         
    
    if @partition_id is not null
    begin
        if exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid and partition_options = 3)
        begin
            if exists (select 1 from dbo.sysmergesubscriptions 
                    where pubid = @pubid and partition_id = @partition_id and subid<>@subid)
            begin
                raiserror(22525, 16, -1, @publication)
                return 1
            end
        end
        update dbo.sysmergesubscriptions set partition_id = @partition_id where subid = @subid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end
    
    if @replica_version is not null
    begin
        update dbo.sysmergesubscriptions set replica_version = @replica_version where subid = @subid
        if @@error <> 0     
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
    end
    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetreplicainfo] TO [public] AS [dbo]
GO
