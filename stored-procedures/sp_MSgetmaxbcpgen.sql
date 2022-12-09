SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetmaxbcpgen]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetmaxbcpgen] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetmaxbcpgen]
	@max_closed_gen [bigint] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
        return 1

    select @max_closed_gen = max(g.generation) 
        from MSmerge_genhistory g,
        (select isnull(gen2.generation, gen1.generation) as generation
            from (select max(generation) as generation from dbo.MSmerge_genhistory where genstatus in (1,2)) as gen1,
                 (select min(generation) as generation from dbo.MSmerge_genhistory where genstatus in (0,4)) as gen2
        ) as minopengen
    where g.generation <= minopengen.generation and g.genstatus in (1,2)

    if @max_closed_gen is NULL
        select @max_closed_gen = 0
GO
GRANT EXECUTE ON [sys].[sp_MSgetmaxbcpgen] TO [public] AS [dbo]
GO
