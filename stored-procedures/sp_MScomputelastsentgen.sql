SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScomputelastsentgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScomputelastsentgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScomputelastsentgen]
	@repid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @mingen         bigint
    declare @lastsentgen    bigint
    declare @lastsentguid   uniqueidentifier
    
    -- this proc should be called on the subscriber. Hence dbo check is good
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return 1

    select @lastsentgen = max(g.generation) 
        from MSmerge_genhistory g,
        (select isnull(gen2.generation, gen1.generation) as generation
            from (select max(generation) as generation from dbo.MSmerge_genhistory where genstatus in (1,2)) as gen1,
                 (select min(generation) as generation from dbo.MSmerge_genhistory where genstatus in (0,4)) as gen2
        ) as minopengen
    where g.generation <= minopengen.generation and g.genstatus in (1,2)
    
    if @lastsentgen is not NULL
    begin
        select @lastsentguid = guidsrc from dbo.MSmerge_genhistory where generation = @lastsentgen
        exec @retcode = sys.sp_MSsetlastsentgen @repid, @lastsentgen, @lastsentguid
        if @@error <> 0 or @retcode <> 0
        begin
            -- should never get here
            RAISERROR('Setting sentgen failed.', 16, -1)
            return 1
        end
    end

GO
GRANT EXECUTE ON [sys].[sp_MScomputelastsentgen] TO [public] AS [dbo]
GO
