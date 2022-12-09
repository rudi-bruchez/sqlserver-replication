SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetlastsentgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetlastsentgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetlastsentgen]
	@repid [uniqueidentifier],
	@srcgen [bigint],
	@srcguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
/*
    ** Check to see if current publication has permission
    */
    declare @retcode    int
    declare @pubid      uniqueidentifier
    declare @subscription_type smallint

    -- if this is the light weight client we have nothing to set here
    if object_id('dbo.MSmerge_rowtrack', 'U') is not null
        return 0
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if (@repid is null)
    begin
        RAISERROR(14043, 16, -1, '@repid', 'sp_MSsetlastsentgen')
        return (1)
    end

    if object_id('MSmerge_contents') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end

    /* 
    ** This is a special case which is used to update the anonymous subscriptions sent and 
    ** received generation guids at the end of initializing a dynamic subscription. This is 
    ** used in the case where an anonymous subscription is reinitialized after a merge metadata
    ** cleanup
    */
    if (@srcgen is null and @srcguid is null)
    begin

        declare @lastrecsentgen     bigint
        declare @lastrecsentguid    uniqueidentifier

        select @lastrecsentgen = max(g.generation) 
            from MSmerge_genhistory g,
            (select isnull(gen2.generation, gen1.generation) as generation
                from (select max(generation) as generation from dbo.MSmerge_genhistory where genstatus in (1,2)) as gen1,
                        (select min(generation) as generation from dbo.MSmerge_genhistory where genstatus in (0,4)) as gen2
            ) as minopengen
        where g.generation <= minopengen.generation and g.genstatus in (1,2)
        if @lastrecsentgen IS NOT NULL
            select @lastrecsentguid = guidsrc from dbo.MSmerge_genhistory where generation = @lastrecsentgen
        update dbo.sysmergesubscriptions set last_local_sentgen = case when sentgen = @lastrecsentgen then last_local_sentgen else sentgen end, sentgen = @lastrecsentgen, sentguid = @lastrecsentguid
            where subid = @repid
        IF @@ERROR <>0 return (1)
    end
    else
    begin
        -- check for setting a sentgen which is obviously too high
        if (exists (select * from dbo.MSmerge_genhistory where generation < @srcgen and
                    genstatus in (0,4) and
                    (art_nick = 0 or art_nick is null or art_nick in
                        (select nickname from dbo.sysmergearticles where
                                pubid = @pubid) )))
        begin
            RAISERROR('Setting sentgen too high', 16, -1)
            return (1)
        end
        update dbo.sysmergesubscriptions set last_local_sentgen = case when sentgen = @srcgen then last_local_sentgen else sentgen end, sentgen = @srcgen, sentguid = @srcguid 
            where subid = @repid
        IF @@ERROR <>0 return (1)
    end         
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetlastsentgen] TO [public] AS [dbo]
GO
