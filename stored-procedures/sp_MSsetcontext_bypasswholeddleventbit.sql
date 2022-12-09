SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetcontext_bypasswholeddleventbit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetcontext_bypasswholeddleventbit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetcontext_bypasswholeddleventbit]
	@onoff [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @cur_context varbinary(128)
    declare @cur_context_first_byte binary(1)
    declare @bitmask tinyint
    declare @retcode int

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_subscribe_withddladmin
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)
    
    -- bit to set: snapshot=1, logreader=2, distrib=4, merge=8, 
    -- replication_agent=16, merge_identityrange_alterconstraint=32
    -- merge_bypasswholeddleventbit=64
    if @onoff=1
        set @bitmask=64
    else
        set @bitmask=255-64
    
    -- get the current context_info. remember we only want to modify a bit without changing the rest of the info
    select @cur_context = isnull(context_info(),0x00)
    
    -- get the first byte out. the replication agent flags are set in the first byte.
    select @cur_context_first_byte = substring(@cur_context, 1, 1)
    -- set the appropriate bit in this one byte (leaving other bits unchanged).
    if @onoff=1
        select @cur_context_first_byte = (convert(tinyint,@cur_context_first_byte) | @bitmask)
    else
        select @cur_context_first_byte = (convert(tinyint,@cur_context_first_byte) & @bitmask)
        
    -- replace the first byte of the 128 byte binary variable, so that now it has the appropriate bit set.
    select @cur_context = convert(varbinary(128),stuff (@cur_context, 1, 1, @cur_context_first_byte))
    -- set the context_info again with the new binary(128) value.
    set context_info @cur_context
    
    if @@error <> 0
        return 1
        
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetcontext_bypasswholeddleventbit] TO [public] AS [dbo]
GO
