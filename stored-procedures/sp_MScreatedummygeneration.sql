SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatedummygeneration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatedummygeneration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatedummygeneration]
	@pubid [uniqueidentifier],
	@maxgen_whenadded [bigint]
WITH EXECUTE AS CALLER
AS
declare @retcode    int
    declare @gen        bigint
    declare @tablenick    int
    declare @nickbin    varbinary(255)
    declare @replnick    binary(6)

    /*
    ** Check to see if current publication has permission
    */
    if ({ fn ISPALUSER(@pubid)} <> 1)
    begin    
        RAISERROR (14126, 11, -1)
        return (1)
    end

    -- get the makegeneration applock before calling makegeneration
    declare @lock int
    -- if there exists any open generations below the maxgen_whenadded then call make generation
    -- with flag @gencheck set to 3 to indicate that all existing open generations lower than 
    -- the highest closed generation should either be closed or deleted
    if exists (select * from dbo.MSmerge_genhistory where generation <= @maxgen_whenadded and genstatus in (0, 4) )
    begin
        exec @retcode = sys.sp_MSgetmakegenerationapplock @head_of_queue = @lock OUTPUT
        -- error out if we could not get the makegeneration applock
        if @@error <> 0 or @retcode < 0
            return 1
        
        -- if there exists any open generations at or below the maxgen_whenadded then call make generation
        if exists (select * from dbo.MSmerge_genhistory where generation <= @maxgen_whenadded and genstatus in (0, 4))
        begin
            exec @retcode = sys.sp_MSmakegeneration @gencheck = 3
            if @@error <> 0 or @retcode <> 0
            begin
                exec sys.sp_MSreleasemakegenerationapplock
                return 1
            end
        end
        exec sys.sp_MSreleasemakegenerationapplock
    end

    -- insert a dummy closed generation so that the watermark after the download is set higher than maxgen_whenadded.
    if not exists (select 1 from dbo.MSmerge_genhistory where generation > @maxgen_whenadded)
    begin
        exec @retcode= sys.sp_MSgetreplnick @replnick = @replnick out
        if @retcode<>0 or @@error<>0 
            return 1

        -- add a guard byte
        set @nickbin= @replnick + 0xFF
        
        insert into dbo.MSmerge_genhistory with (rowlock)
            (guidsrc, genstatus, art_nick, nicknames, coldate) 
        values (newid(), 1, 0, @nickbin, getdate())
        if @@error<>0
            return 1
    end
    return 0
                        
GO
GRANT EXECUTE ON [sys].[sp_MScreatedummygeneration] TO [public] AS [dbo]
GO
