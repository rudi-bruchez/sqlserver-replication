SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetchangecount]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetchangecount] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetchangecount]
	@startgen [bigint],
	@changes [int] OUTPUT,
	@updates [int] OUTPUT,
	@deletes [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
        -- security check
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck
        if @@error <> 0 or @retcode <> 0
                return 1
                
    select @deletes = count(*) from dbo.MSmerge_tombstone where generation = 0 or generation > @startgen
    select @updates = count(*) from dbo.MSmerge_contents where generation = 0 or generation > @startgen
    select @changes = @updates + @deletes
    return (0)      
GO
GRANT EXECUTE ON [sys].[sp_MSgetchangecount] TO [public] AS [dbo]
GO
