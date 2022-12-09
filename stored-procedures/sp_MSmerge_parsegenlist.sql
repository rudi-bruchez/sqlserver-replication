SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmerge_parsegenlist]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmerge_parsegenlist] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmerge_parsegenlist]
	@genlist [varchar](8000),
	@gendeclarelist [varchar](max) OUTPUT,
	@genselectlist [varchar](max) OUTPUT,
	@genunionlist [varchar](max) OUTPUT
WITH EXECUTE AS CALLER
AS
declare @gencount int	
    declare @counter int
    declare @listsize int
    declare @position1 int
    declare @position2 int
		    
    select @gendeclarelist = ' '
    select @genselectlist = ' '
    select @genunionlist = ' '

    exec sys.sp_MSmerge_getgencount @genlist, @gencount output
	
    if @gencount = 0
        return

	-- for better performance of enum queries, limit the number of queries by
	-- using a small set of gen buckets
    if @gencount <= 10
        set @listsize = 10
    else if @gencount <= 25
        set @listsize = 25
    else if @gencount <= 50
        set @listsize = 50
    else if @gencount <= 100
        set @listsize = 100
    else if @gencount <= 200
        set @listsize = 200
    else if @gencount <= 500
        set @listsize = 500
    else if @gencount <= 1000
        set @listsize = 1000
    else if @gencount <= 1500
        set @listsize = 1500
    else if @gencount <= 2000
        set @listsize = 2000
    else
        set @listsize = @gencount

    if @listsize <> 0 and @gencount > @listsize
        return 

    -- if we get this far, we have at least one gen 
    set @counter = 1
    set @position1 = 1
    set @position2 = charindex(',', @genlist, @position1)

    declare @tempint bigint	        		

    while @counter < @listsize 
    begin		        		
        select @gendeclarelist = @gendeclarelist + '
    declare @gen' + convert(varchar(16), @counter) + ' bigint '
		
        if @counter < @gencount
        begin
            select @tempint = CONVERT(bigint, substring(@genlist, @position1, @position2 - @position1))
            select @genselectlist = @genselectlist + '
    select @gen' + convert(varchar(16), @counter) + ' =  ' + CONVERT(varchar(20), @tempint)
        end
        else if @counter = @gencount
        begin
            select @tempint = CONVERT(bigint, substring(@genlist, @position1, len(@genlist) - (@position1-1)))
            select @genselectlist = @genselectlist + '
    select @gen' + convert(varchar(16), @counter) + ' =  ' + CONVERT(varchar(20), @tempint)
        end
        else
            select @genselectlist = @genselectlist + '
    select @gen' + convert(varchar(16), @counter) + ' =  null '

        select @genunionlist = @genunionlist + '
            select @gen' + + convert(varchar(16),@counter) + ' as gen union all '
	
        set @counter = @counter + 1
        set @position1 = @position2 + 1
        set @position2 = charindex(',', @genlist, @position1)               				
    end		
	
    -- parse last gen in the list
        select @gendeclarelist = @gendeclarelist + '
    declare @gen' + convert(varchar(16), @counter) + ' bigint '
	
    if @counter = @gencount 
    begin
        select @tempint = CONVERT(bigint, substring(@genlist, @position1, len(@genlist) - (@position1-1)))
        select @genselectlist = @genselectlist + '
    select @gen' + convert(varchar(16), @counter) + ' =  ' + CONVERT(varchar(20), @tempint)
    end
    else 
        select @genselectlist = @genselectlist + '
    select @gen' + convert(varchar(16), @counter) + ' =  null '

        select @genunionlist = @genunionlist + '
        select @gen' + + convert(varchar(16), @counter) + ' as gen '
	    
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSmerge_parsegenlist] TO [public] AS [dbo]
GO
