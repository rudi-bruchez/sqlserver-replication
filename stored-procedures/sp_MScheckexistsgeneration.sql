SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheckexistsgeneration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheckexistsgeneration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheckexistsgeneration]
	@genguid [uniqueidentifier],
	@gen [bigint] OUTPUT,
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    /*
    ** Check input parameter
    */
    if (@genguid is null)
        begin
            RAISERROR(14043, 16, -1, '@genguid', 'sp_MScheckexistsgeneration')
            return (1)
        end

    -- security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    /* Normal case : do not qualify by pubid */
    if (@pubid IS NULL)
        select @gen = max(generation) from dbo.MSmerge_genhistory where guidsrc = @genguid and genstatus in (1,2)
    else        
    /* If we are reinitializing from an alternate publisher, check if the subscription has received generations for the alternate publication */
        select @gen = max(generation) from dbo.MSmerge_genhistory where guidsrc = @genguid and genstatus in (1,2)
            and ((pubid = @pubid) or (pubid is null))       
    IF @@ERROR <>0 return (1)
    /* OLEDB does not allow output parameter to be NULL - setting it to 0 */
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MScheckexistsgeneration] TO [public] AS [dbo]
GO
