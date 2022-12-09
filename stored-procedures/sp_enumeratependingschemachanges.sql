SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_enumeratependingschemachanges]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_enumeratependingschemachanges] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_enumeratependingschemachanges]
	@publication [sysname],
	@starting_schemaversion [int]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode    int
    declare @pubid      uniqueidentifier
    declare @SCHEMA_TYPE_SNAPSHOTTRAILER int
    declare @snapshot_trailer_schemaversion int

    select @retcode = 0
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)

    if @publication IS NULL
    begin
        raiserror (14003, 16, -1)
        return (1)
    end
    select @pubid = pubid FROM dbo.sysmergepublications WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (21274, 16, -1, @publication)
        return (1)
    end
    

    set @SCHEMA_TYPE_SNAPSHOTTRAILER = 52
    select @snapshot_trailer_schemaversion = schemaversion from dbo.sysmergeschemachange 
        where pubid=@pubid and schematype = @SCHEMA_TYPE_SNAPSHOTTRAILER
    if (@starting_schemaversion <= @snapshot_trailer_schemaversion) 
        set @starting_schemaversion = @snapshot_trailer_schemaversion + 1
    create table #pendingschemachanges 
    (   
        article_name    sysname           NULL,
        schemaversion   int               NOT NULL,
        schematype      sysname           NOT NULL,
        schematext      nvarchar(max)     collate database_default not null,
        schemastatus    nvarchar(10)      NOT NULL,
        schemaguid      uniqueidentifier  NOT NULL
    )
        
    truncate table #pendingschemachanges
    insert into #pendingschemachanges 
        select distinct case (isnull(ma.artid, '00000000-0000-0000-0000-000000000000')) when  '00000000-0000-0000-0000-000000000000' then 'Publication-wide' else ma.name end, 
            sc.schemaversion, sys.fn_MapSchemaType(sc.schematype, sc.schemasubtype), sc.schematext, 
            case sc.schemastatus 
                when 0 then 'inactive'
                when 1 then 'active'
                when 2 then 'skip'
                else 'invalid'
            end, sc.schemaguid
        from dbo.sysmergeschemachange sc left outer join dbo.sysmergearticles ma on sc.artid = ma.artid
            where sc.pubid=@pubid and 
              sc.schemaversion >= (@starting_schemaversion) order by schemaversion

    select * from  #pendingschemachanges            
    drop table #pendingschemachanges
              
end
GO
GRANT EXECUTE ON [sys].[sp_enumeratependingschemachanges] TO [public] AS [dbo]
GO
