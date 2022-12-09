SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheckidentityrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheckidentityrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheckidentityrange]
	@pubid [uniqueidentifier],
	@artname [sysname],
	@next_seed [bigint],
	@range [bigint],
	@threshold [int],
	@checkonly [int]
WITH EXECUTE AS CALLER
AS
declare @colid              int
    declare @colname            sysname
    declare @retcode            int
    declare @objid              int
    declare @identity_so_far    bigint
    declare @current_max        bigint
    declare @max_identity       bigint
    declare @tablename          sysname
    declare @pub_range          bigint
    declare @lightweight                bit
    
    declare @xe_message varbinary(1000)

        /*
        ** Check to see if current publication has permission
        */
        if ({ fn ISPALUSER(@pubid)} <> 1)
        begin   
                RAISERROR (14126, 11, -1)
                return (1)
        end

    -- this proc will never be called in yukon except for light weight subscribers
        set @lightweight=sys.fn_MSuselightweightreplication(null, null, null, @pubid, null, null, null)
        if @lightweight = 0
        begin
            raiserror('sp_MScheckidentityrange should not have been called', 16, -1)
            return 1
        end

    select @objid = objid from dbo.sysmergearticles where pubid=@pubid and name=@artname
    if @objid is NULL
        begin
            raiserror(20027, 16, -1, @artname)
            return 1
        end
    
    select @tablename=object_name(@objid)

        begin tran
    save TRAN sp_MScheckidentityrange

        if @checkonly=1
        begin
                select @max_identity= max_identity from MSmerge_idrange where objid=@objid
                if @max_identity is null goto FAILURE

                set @identity_so_far= isnull(ident_current(@tablename), ident_seed(@tablename))

                select @xe_message = CAST('Article: ' + @artname + ', max_identity: ' + convert(nvarchar(100), @max_identity) + ', identity_current: ' + convert(nvarchar(100), @identity_so_far) AS varbinary(1000))
                exec master..sp_repl_generateevent 1, N'Event : identity_range_check', @xe_message

                select case
                        when (@max_identity - @identity_so_far) * 100 / @range < (100 - @threshold) then 1 -- needs bump up
                        else 0 -- no need to bump up
                end
        end
    else
    begin
        update MSmerge_idrange set max_identity=@next_seed + @range
                where objid = @objid

        select @xe_message = CAST('Article: ' + @artname + ', next_seed: ' + convert(nvarchar(100), @next_seed) + ', range: ' + convert(nvarchar(100), @range) AS varbinary(1000))
        exec master..sp_repl_generateevent 1, N'Event : identity_range_check', @xe_message
        
        exec sys.sp_MSreseed @objid, @next_seed, @range 
        if @@ERROR <> 0 
            goto FAILURE
    end

        commit tran
        return 0
        
FAILURE:
   select 0
        if @@TRANCOUNT > 0
    begin
        ROLLBACK TRAN sp_MScheckidentityrange
        COMMIT TRAN
    end
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MScheckidentityrange] TO [public] AS [dbo]
GO
