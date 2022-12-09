SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSisreplmergeagent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSisreplmergeagent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSisreplmergeagent]
	@is_merge [bit] OUTPUT,
	@at_publisher [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    declare @cur_context varbinary(128)
    declare @cur_context_first_byte binary(1)
    declare @mergeagent_bitmask tinyint
    declare @atpublisher_bitmask tinyint
        
    select @mergeagent_bitmask = 8        --     snapshot=1, logreader=2, distrib=4, merge=8
    select @atpublisher_bitmask = 16
    
    select @cur_context = isnull(context_info(),0x00)
    
    -- get the first byte out of the 128 byte array.
    select @cur_context_first_byte = substring(@cur_context, 1, 1)
    
    -- check whether it has the merge agent bit set.
    select @mergeagent_bitmask = (convert(tinyint,@cur_context_first_byte) & @mergeagent_bitmask)
    -- set the output param value appropriately.
    select @is_merge = case when @mergeagent_bitmask = 0 then 0 else 1 end
    
    -- check whether it has the "at publisher" bit set.
    select @atpublisher_bitmask = (convert(tinyint,@cur_context_first_byte) & @atpublisher_bitmask)
    -- set the output param value appropriately.
    select @at_publisher = case when @atpublisher_bitmask = 0 then 0 else 1 end

    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSisreplmergeagent] TO [public] AS [dbo]
GO
