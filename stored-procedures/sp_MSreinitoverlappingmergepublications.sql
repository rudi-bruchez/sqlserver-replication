SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreinitoverlappingmergepublications]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreinitoverlappingmergepublications] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreinitoverlappingmergepublications]
	@pubid [uniqueidentifier],
	@upload_before_reinit [bit]
WITH EXECUTE AS CALLER
AS
declare @publisher sysname
    declare @publisher_db sysname
    declare @publication_current sysname
    declare @pubid_current uniqueidentifier
    declare @pubid_previous uniqueidentifier
    declare @retcode int

    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    set @publisher= publishingservername()
    set @publisher_db= db_name()
    set @retcode= 0

    while 1=1
    begin
        set @pubid_previous= @pubid_current
        set @pubid_current= null
        
        select top 1 @publication_current= repub_smp.name,
                     @pubid_current= repub_smp.pubid
            from dbo.sysmergearticles as pub_sma 
                 inner join 
                 dbo.sysmergearticles as repub_sma on pub_sma.artid=repub_sma.artid
                 inner join
                 dbo.sysmergepublications as repub_smp on repub_sma.pubid=repub_smp.pubid
            where pub_sma.pubid=@pubid and 
                  pub_sma.pubid<>repub_sma.pubid and
                  repub_smp.publisher collate database_default=@publisher collate database_default and
                  repub_smp.publisher_db=@publisher_db and
                  (repub_smp.pubid > @pubid_previous or @pubid_previous is null)
            order by repub_smp.pubid asc

        if @pubid_current is null
        begin
            break
        end

        exec @retcode= sys.sp_MSreinitmergepublication
                                @publication= @publication_current,
                                @upload_first= @upload_before_reinit

        if @@error<>0 or @retcode<>0 return 1

    end

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSreinitoverlappingmergepublications] TO [public] AS [dbo]
GO
