SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetcontext_replagent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetcontext_replagent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetcontext_replagent]
	@agent_type [tinyint],
	@is_publisher [bit]
WITH EXECUTE AS CALLER
AS
begin
declare @cur_context varbinary(128)
declare @cur_context_first_byte binary(1)
declare @bitmask tinyint

-- agent type: snapshot=1, logreader=2, distrib=3, merge=4
-- bit to set: snapshot=1, logreader=2, distrib=4, merge=8
select @bitmask =    case     
                        when @agent_type = 1 then 1 
                        when @agent_type = 2 then 2
                        when @agent_type = 3 then 4
                        when @agent_type = 4 then 8
                    end

if @is_publisher = 1
    select @bitmask = (@bitmask | 16)

select @cur_context = isnull(context_info(),0x00)

-- get the first byte out. the replication agent flags are set in the first byte.
select @cur_context_first_byte = substring(@cur_context, 1, 1)
-- set the appropriate bit in this one byte (leaving other bits unchanged).
select @cur_context_first_byte = (convert(tinyint,@cur_context_first_byte) | @bitmask)
-- replace the first byte of the 128 byte binary variable, so that now it has the appropriate bit set.
select @cur_context = convert(varbinary(128),stuff (@cur_context, 1, 1, @cur_context_first_byte))
-- set the context_info again with the new binary(128) value.
set context_info @cur_context

if @@error <> 0
    return 1
    
return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetcontext_replagent] TO [public] AS [dbo]
GO
