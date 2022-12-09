SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_getgencount]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_getgencount] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_getgencount]
	@genlist [varchar](8000),
	@gencount [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @position1 int
    declare @position2 int

    set @gencount = 0
	
    if len(@genlist) = 0 or @genlist is NULL
        return

    -- determine number of generations in genlist  
    -- if we get this far, we have at least one gen
    set @gencount = 1
    set @position1 = 1
    set @position2 = charindex(',', @genlist, @position1)

    while @position2 > 0
    begin
        set @gencount = @gencount + 1
        set @position1 = @position2 + 1
        set @position2 = charindex(',', @genlist, @position1)
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_getgencount] TO [public] AS [dbo]
GO
