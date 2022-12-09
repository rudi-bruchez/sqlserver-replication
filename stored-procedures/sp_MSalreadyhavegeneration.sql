SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSalreadyhavegeneration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSalreadyhavegeneration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSalreadyhavegeneration]
	@genguid [uniqueidentifier],
	@subscribernick [binary](6),
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
declare @nicknames varbinary(1000)
    declare @offset int
    declare @retcode int
    declare @dbname sysname
    
    -- Security Checking 
    -- PAL users have access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    if (@genguid is null)
    begin
        RAISERROR(14043, 16, -1, '@genguid', 'sp_MSalreadyhavegeneration')
        return (1)
    end

    select @nicknames = nicknames from dbo.MSmerge_genhistory where guidsrc = @genguid
    if @nicknames is null
    begin
        set @dbname= db_name()
        -- what is the appropriate error to return?
        RAISERROR(21333, 16, -1, @dbname)
        return (1)
    end

    if @compatlevel < 90
        set @subscribernick= substring(@subscribernick,1,4) + 0x0000

    declare @replnicklength int
    set @replnicklength= col_length('sysmergesubscriptions', 'replnickname')
    set @offset= 1
    while @offset < DATALENGTH(@nicknames)
    begin
        -- If the subscriber nickname is already in the list just return
        if substring(@nicknames, @offset, @replnicklength) = @subscribernick
            return (0)
        set @offset = @offset + @replnicklength
    end
    
    -- Subscriber nickname is not in the array.  Add it so that we won't send this gen
    -- back down in the return message.  (Would waste bandwidth...)

    -- Append guard byte
        set @offset = DATALENGTH(@nicknames)
    if substring(@nicknames, @offset, 1) <> 0xFF
        begin
                set @nicknames = @nicknames + 0xFF
        end

    if @nicknames = 0x0
        set @nicknames = @subscribernick + 0xFF
    else
        set @nicknames = @subscribernick + @nicknames

    update dbo.MSmerge_genhistory set nicknames = @nicknames where guidsrc = @genguid
    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSalreadyhavegeneration] TO [public] AS [dbo]
GO
