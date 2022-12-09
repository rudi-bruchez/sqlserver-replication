SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_markpendingschemachange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_markpendingschemachange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_markpendingschemachange]
	@publication [sysname],
	@schemaversion [int],
	@status [nvarchar](10)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode        int
    declare @pubid          uniqueidentifier
    declare @compatlevel    int
    declare @statusid       int
    declare @SCHEMA_TYPE_SNAPSHOTTRAILER int
    
    select @retcode = 0
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)

    if @publication IS NULL
    begin
        raiserror (14003, 16, -1)
        return (1)
    end

    select @pubid = pubid, @compatlevel = backward_comp_level FROM dbo.sysmergepublications WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (21274, 16, -1, @publication)
        return (1)
    end
    
    if @compatlevel < 90
    begin
        raiserror(22557, 16, -1, @publication)
        return 1
    end

    select @status  = lower(@status  collate SQL_Latin1_General_CP1_CS_AS)
    if @status  not in ('active', 'skipped')
    begin
        RAISERROR(22559 , 16, -1)
        return (1)
    end

    if @status = N'active'
        select @statusid = 1
    else if @status = N'skipped'
        select @statusid = 2
    
    update dbo.sysmergeschemachange set schemastatus = @statusid
        where pubid=@pubid and schemaversion = @schemaversion 
    if @@error <> 0 or @@rowcount <> 1
        begin
            RAISERROR(22558 , 16, -1)
            return (1)
        end     
    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_markpendingschemachange] TO [public] AS [dbo]
GO
