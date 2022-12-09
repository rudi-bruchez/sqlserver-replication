SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adjustpublisheridentityrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adjustpublisheridentityrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adjustpublisheridentityrange]
	@publication [sysname],
	@table_name [sysname],
	@table_owner [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on

declare @retcode                 int, @object_found bit
declare @objid                    int
declare @qualified_table_name    nvarchar(260)
declare @identity_support        int
declare @pubid                    uniqueidentifier

select @object_found = 0

/*
** Security Check
*/
EXEC @retcode = sys.sp_MSreplcheck_publish
IF @@ERROR <> 0 or @retcode <> 0
    return (1)

if ((@publication is NULL and @table_name is NULL) or 
        (@publication is not NULL and @table_name is not NULL))
begin
    raiserror(21314, 16, -1, '@publication', '@table_name')
    return (1)
end

if @publication is NULL
begin
    if @table_owner is NULL
        select @table_owner = schema_name()
    select @qualified_table_name = QUOTENAME(@table_owner) + '.' + QUOTENAME(@table_name)
    
    select @objid = object_id(@qualified_table_name)
    if @objid is NULL
    begin 
        RAISERROR (14027, 11, -1, @qualified_table_name)
        return (1)
    end
end

--Do this for merge?
if object_id('sysmergepublications') is not NULL
begin
    if @publication is NULL
    begin
        select @identity_support = identity_support from dbo.sysmergearticles where objid=@objid
        if @identity_support is not null
        begin
            select @object_found = 1
            if @identity_support = 0
                return (0)
            exec @retcode = sys.sp_MSadjustmergeidentity @qualified_table_name=@qualified_table_name    
            if @retcode<>0 or @@ERROR<>0
            begin
                raiserror(21315, 16, -1, @table_name)
                return (1)
            end
        end
    end

    if @table_name is NULL
    begin
        select @pubid=pubid FROM dbo.sysmergepublications
            WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
        if @pubid is not null
        begin
            select @object_found = 1
            if not exists (select * from dbo.sysmergearticles where pubid=@pubid and identity_support=1)
                return (0)
            exec @retcode = sys.sp_MSadjustmergeidentity @publication=@publication
            if @retcode<>0 or @@ERROR<>0
            begin
                raiserror(21316, 16, -1, @publication)
                return (1)
            end    
        end    
    end
end

if object_id('syspublications') is not NULL
begin
    if @publication is NULL
    begin
        declare @artid int
        select top 1 @artid = artid from sysarticles where 
            objid = @objid
        if @artid is not null
        begin
            select @object_found = 1
            exec @retcode = sys.sp_MSpub_adjust_identity @artid
            if @retcode<>0 or @@ERROR<>0
                return (1)
        end
    end
    else
    begin
        declare @publication_id int
        select @publication_id = pubid from syspublications where name = @publication
        if @publication_id is not null
        begin
            select @object_found = 1
            DECLARE adjust_identity CURSOR LOCAL FAST_FORWARD FOR
                SELECT art1.objid
                  FROM sysarticles art1,
                       sysarticleupdates art2
                  where art1.pubid = @publication_id and
                        art1.artid = art2.artid and
                        art2.identity_support = 1 and
                        (art1.artid = @artid or @artid is null)
            FOR READ ONLY

            OPEN adjust_identity        
            FETCH adjust_identity INTO @objid
            WHILE (@@fetch_status <> -1)
            begin
                exec @retcode = sys.sp_MSpub_adjust_identity @artid
                if @retcode<>0 or @@ERROR<>0
                    return (1)
                FETCH adjust_identity INTO @objid
            end
        end
    end
end
if @object_found = 0
begin
    if @publication is null
        raiserror(21246, 16, -1, @qualified_table_name)
    else
        RAISERROR (20026, 11, -1, @publication)
end

RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_adjustpublisheridentityrange] TO [public] AS [dbo]
GO
