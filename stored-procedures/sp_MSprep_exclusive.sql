SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSprep_exclusive]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSprep_exclusive] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSprep_exclusive]
	@objname [sysname],
	@objid [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @retcode int
    			,@tran_pubname sysname

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    if @objname is NULL
    begin
        RAISERROR (14043, 16, -1, '@objname', 'sp_MSprep_exclusive')
        return (1)
    end

	if(@objid is NULL)
	begin
	    select @objid = object_id(@objname)
	    if @objid is NULL
	    begin
	        raiserror(14027, 16, -1, @objname)
	        return (1)
	    end

	    exec sys.sp_replupdateschema @objname
	    if @@ERROR<>0
	        return (1)
    end

    declare #trancolumn CURSOR LOCAL FAST_FORWARD for 
            select p.name from sysarticles a join 
            									syspublications p on p.pubid = a.pubid
            						where a.objid=@objid
    open #trancolumn
    fetch #trancolumn into @tran_pubname
    while (@@fetch_status <> -1)
    BEGIN
        EXEC @retcode = sys.sp_getapplock   @Resource = @tran_pubname, 
                        @LockMode = N'Exclusive', 
                        @LockOwner = N'Transaction', 
                        @LockTimeout = 0,
                        @DbPrincipal = N'db_owner' -- Note that we already require db_owner due to security check at the beginning of the stored procedure.
        if @retcode = -1
        begin 
            raiserror(21386, 16, -1, @objname)
            goto FAILURE    
        end 
        if @@ERROR<>0 or @retcode < 0
            goto FAILURE
        fetch #trancolumn into @tran_pubname            
    END
    close #trancolumn
    deallocate #trancolumn
    return 0
FAILURE:
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_MSprep_exclusive] TO [public] AS [dbo]
GO
