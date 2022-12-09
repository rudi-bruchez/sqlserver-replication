SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetlastrecgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetlastrecgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetlastrecgen]
	@repid [uniqueidentifier],
	@srcgen [bigint],
	@srcguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
/*
    ** Check to see if current publication has permission
    */
    declare @retcode    int

    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    if (@repid is null)
    begin
        RAISERROR(14043, 16, -1, '@repid', 'sp_MSsetlastrecgen')
        return (1)
    end
    if (@srcgen is null)
    begin
        RAISERROR(14043, 16, -1, '@srcgen', 'sp_MSsetlastrecgen')
        return (1)
    end
    if (@srcguid is null)
    begin
        RAISERROR(14043, 16, -1, '@srcguid', 'sp_MSsetlastrecgen')
        return (1)
    end
    if object_id('MSmerge_contents') is NULL and
       object_id('MSmerge_rowtrack') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    update dbo.sysmergesubscriptions set recgen = @srcgen, recguid = @srcguid,
                                         last_local_recgen = case when recguid = @srcguid or recguid is null or recguid = '00000000-0000-0000-0000-000000000000' then last_local_recgen else NULL end,
                                         last_local_recguid = case when recguid = @srcguid or recguid is null or recguid = '00000000-0000-0000-0000-000000000000' then last_local_recguid else recguid end
        where subid = @repid
    IF @@ERROR <>0 return (1) 
   
    return (0)

GO
GRANT EXECUTE ON [sys].[sp_MSsetlastrecgen] TO [public] AS [dbo]
GO
