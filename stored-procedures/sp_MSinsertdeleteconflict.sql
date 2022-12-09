SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinsertdeleteconflict]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinsertdeleteconflict] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinsertdeleteconflict]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@conflict_type [int],
	@reason_code [int],
	@reason_text [nvarchar](720),
	@origin_datasource [nvarchar](255),
	@pubid [uniqueidentifier],
	@lineage [varbinary](311),
	@conflicts_logged [int] OUTPUT,
	@compatlevel [int],
	@source_id [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    select @source_id = newid()
    /*
    ** Check to see if current publication has permission
    */
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        if (@pubid is NULL)
        begin
                RAISERROR (21723, 16, -1, 'sp_MSinsertdeleteconflict')
                return 1
        end
        else
        begin
                RAISERROR (14126, 11, -1)
                return 1
        end
    end

    /* Parameter validation */
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSinsertdeleteconflict')
        return (1)
    end
    if (@rowguid is null)
    begin
        RAISERROR(14043, 16, -1, '@rowguid', 'sp_MSinsertdeleteconflict')
        return (1)
    end

        if object_id('sysmergearticles') is NULL
        begin
            RAISERROR(20054 , 16, -1)
            return (1)
        end
        
        /*if @conflict_type not in (4,7,8,12)
        begin
                raiserror(21344, 16, -1, '@conflict_type')
                return 1
        end*/

        /* Don't insert a duplicate row */
        if not exists (select * from MSmerge_conflicts_info where tablenick = @tablenick and
                rowguid = @rowguid and origin_datasource = @origin_datasource
                and conflict_type in (4,7,8,12))
        begin
                insert into MSmerge_conflicts_info
                        (tablenick, rowguid, conflict_type, reason_code, reason_text, origin_datasource, pubid, origin_datasource_id) values
                        (@tablenick, @rowguid, @conflict_type, @reason_code, @reason_text, @origin_datasource, @pubid, @source_id)
                select @conflicts_logged = @@ROWCOUNT
                if @@ERROR <> 0 return (1)
        end
        /* Update the existing row - but do not use a generic message to update an error */
        else if (exists (select * from MSmerge_conflicts_info where tablenick = @tablenick and
                                rowguid = @rowguid and origin_datasource = @origin_datasource and 
                                (conflict_type<5 or @conflict_type>4)))
        begin                           
                update MSmerge_conflicts_info set conflict_type = @conflict_type, reason_code = @reason_code,
                        reason_text = @reason_text, origin_datasource_id=@source_id where tablenick = @tablenick and
                        rowguid = @rowguid and origin_datasource = @origin_datasource
                        and conflict_type in (4,7,8,12)
                select @conflicts_logged = @@ROWCOUNT
                if @@ERROR <> 0 return (1)
        end                     
        
        -- If this is an error, add to MSmerge_errorlineage table
        if (@conflict_type in (7, 8) and @lineage is not null)
        begin
                exec @retcode = sys.sp_MSinserterrorlineage @tablenick=@tablenick, @rowguid=@rowguid, @lineage=@lineage, @compatlevel=@compatlevel
                if @retcode<>0 or @@ERROR<>0 return (1)
        end
        
        return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSinsertdeleteconflict] TO [public] AS [dbo]
GO
