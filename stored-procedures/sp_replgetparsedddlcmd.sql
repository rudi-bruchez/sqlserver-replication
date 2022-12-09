SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replgetparsedddlcmd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replgetparsedddlcmd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replgetparsedddlcmd]
	@ddlcmd [nvarchar](max) OUTPUT,
	@FirstToken [sysname],
	@objectType [sysname],
	@dbname [sysname],
	@owner [sysname],
	@objname [sysname],
	@targetobject [nvarchar](512)
WITH EXECUTE AS CALLER
AS
begin
declare @left_quote bigint
		,@right_quote bigint
		,@first_space tinyint
		,@ddlcmd_len bigint
		,@ddloffset nvarchar(max)
		,@trigger_dbname sysname
		,@trigger_owner sysname
		,@trigger_objname sysname
		
-- start with striping off ALTER at the begining
set @ddloffset = ltrim(right(@ddlcmd, len(@ddlcmd) - len(@FirstToken)))

-- strip out any possible comments between alter and next token
set @ddloffset = sys.fn_replremoveleadingcomments(@ddloffset)
set @ddlcmd_len = len(@ddloffset)

-- now strip out objectType token, 
-- remember, this function is only used by DDL trigger where we know @ddlcmd coming in is valid
-- watch out for space after the second token, e.g. alter proc instead of alter procedure
-- watch out for comments, e.g. alter proc/*..*/myproc instead of alter procedure
set @first_space = patindex('% %', @ddloffset)
set @left_quote = patindex('%/*%', @ddloffset)
if (@first_space > 0 and @first_space < len(@objectType))
	or (@left_quote > 0 and @left_quote < len(@objectType))
begin
	if (@first_space > 0) and (@left_quote > 0)
	begin
		if (@left_quote > @first_space)
			set @left_quote = @first_space
	end
	else if (@first_space > 0) and (@left_quote = 0)
		set @left_quote = @first_space
end
else
	set @left_quote = len(@objectType) + 1
set @ddloffset = ltrim(substring(@ddloffset, @left_quote, @ddlcmd_len - @left_quote + 1))

-- strip out any possible comments between @ObjectType token and object name
set @ddloffset = sys.fn_replremoveleadingcomments(@ddloffset)

-- now strip out object name
-- deal with the following possibilities: w or w/o quotes
-- [db].[owner].[obj]
set @ddloffset = sys.fn_replremovefullobj(@ddloffset, @dbname, @owner, @objname)

-- might as well strip out any possible comments between object name and definition
set @ddloffset = sys.fn_replremoveleadingcomments(@ddloffset)

--alter trigger trigger_name on [db].[owner].[obj] as .... has the same issue, parse to the point before as
--so we can substitute with alter trigger trigger_name on [dest_owner].[dest_obj] as 
if UPPER(@objectType) = N'TRIGGER' and @targetobject is not NULL and len(@targetobject) > 0
begin 
	-- remove leading white space char
	declare @pos int
	select @pos=charindex(N'on ', @ddloffset)
	set @ddloffset = substring(@ddloffset, @pos, len(@ddloffset)-@pos+1) 
	
	set @ddloffset = ltrim(right(@ddloffset, len(@ddloffset) - len(N'on ')))

	set @trigger_dbname = isnull(parsename(@targetobject, 3), @dbname)
	set @trigger_owner = isnull(parsename(@targetobject, 2), @owner)
	set @trigger_objname = isnull(parsename(@targetobject, 1), @objname)
	
	set @ddloffset = sys.fn_replremovefullobj(@ddloffset, @trigger_dbname, @trigger_owner, @trigger_objname)
end
set @ddlcmd=@ddloffset
return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replgetparsedddlcmd] TO [public] AS [dbo]
GO
