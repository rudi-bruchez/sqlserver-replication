SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinsertgenhistory]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinsertgenhistory] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinsertgenhistory]
	@guidsrc [uniqueidentifier],
	@gen [bigint] OUTPUT,
	@pubid [uniqueidentifier],
	@pubid_ins [uniqueidentifier],
	@nicknames [varbinary](1000),
	@artnick [int],
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
/*
    ** Check to see if current publication has permission
    */
    declare @retcode int, @replnick binary(6), @newnicks varbinary(1000), @dt datetime
    declare @offset int
    declare @default_nicknames    varbinary(255)
    declare @application_name sysname
    declare @subscriber_number int

    --declare @GENSTATUS_MERGE_INSERTED_OPEN tinyint
    
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
            RAISERROR (21723, 16, -1, 'sp_MSinsertgenhistory')
            return 1
        end
        else
        begin
            RAISERROR (14126, 11, -1)
            return 1
        end
    end
    
    if (@guidsrc is null)
    begin
        RAISERROR(14043, 16, -1, '@guidsrc', 'sp_MSinsertgenhistory')
        return (1)
    end
    
    --select @GENSTATUS_MERGE_INSERTED_OPEN = 4

    -- having the login time in dbo.MSmerge_genhistory allows to associate the row with the merge process that inserted the row
    select @dt = login_time, @application_name = program_name from sys.dm_exec_sessions where session_id = @@spid

    select @subscriber_number = subscriber_number from dbo.sysmergesubscriptions where application_name = @application_name collate database_default
    -- the following will be the case if this is a down level anonymous subscriber. We will give a number of -1 to all such subscribers
    -- a number of 0 is used to indicate locally inserted generations
    if @subscriber_number is NULL
        select @subscriber_number = -1
        
    -- Check for older in process generation
    select @gen = max(generation) from dbo.MSmerge_genhistory where guidsrc = @guidsrc
    if @gen is not null
    begin
        -- this generation was interrupted at a previous merge
        -- next statement makes sure that gen does no longer look interrupted to another process
        update dbo.MSmerge_genhistory set coldate= @dt, genstatus=4, subscriber_number = @subscriber_number where guidsrc = @guidsrc

        -- if @@rowcount = 0, another process removed the interrupted gen just before the previous update statement
        if @@rowcount > 0
        begin
            return (0)
        end
    end

    exec sys.sp_MSgetreplnick @replnick = @replnick out
    if @@ERROR<>0 return (1)

    -- add a guard byte
    set @default_nicknames= @replnick + 0xFF

    if @compatlevel < 90
        set @nicknames = ISNULL({fn REPLNICKARRAY_80_TO_90(@nicknames)},@default_nicknames)

    declare @replnicklength int
    set @replnicklength= col_length('sysmergesubscriptions', 'replnickname')

    set @offset = DATALENGTH(@nicknames)
    if substring(@nicknames, @offset, 1) <> 0xFF
    begin
        set @nicknames = @nicknames + 0xFF
    end
    
    set @newnicks = @nicknames
    
    set @offset = 1
    while @offset < DATALENGTH(@nicknames)
    begin
        -- If the subscriber nickname is already in the list just return
        if substring(@nicknames, @offset, @replnicklength) = @replnick
            goto InsertGenHistory
        set @offset = @offset + @replnicklength
    end
    -- My nickname is not in the array.  Add it so that we won't send this gen back down in the return message.  
    -- Append guard byte
    if @nicknames = 0x0
        set @newnicks = @replnick + 0xFF
    else
    begin
        set @newnicks = @replnick + @nicknames
    end
        
InsertGenHistory:
   insert into dbo.MSmerge_genhistory with (rowlock)
    (guidsrc, pubid, genstatus, art_nick, nicknames, coldate, subscriber_number) 
        values (@guidsrc, @pubid_ins, 4, @artnick,@newnicks, @dt, @subscriber_number)

    if @@error<>0 goto Failure
    select @gen = @@identity
        
    return (0)
Failure:
    RAISERROR(15001, 16, -1, 'MSmerge_genhistory')
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MSinsertgenhistory] TO [public] AS [dbo]
GO
