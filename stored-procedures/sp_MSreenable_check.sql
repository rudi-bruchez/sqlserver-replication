SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreenable_check]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreenable_check] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreenable_check]
	@objname [sysname],
	@objowner [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on
    
    declare @cnstname sysname
    declare @cnstid int
    declare @objid int
    declare @enable_cmd nvarchar(4000)
    declare @dest nvarchar(514)

    declare @retcode int
    IF @objname IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@objname', 'sp_MSreenable_check')
        RETURN (1)
    END

    if(@objowner is not null)
        select @dest = quotename(@objowner) + N'.' + quotename(@objname)
    else
        select @dest = quotename(@objname)

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
            return (1)

    select @objid = object_id(@objname)
    
    declare ms_crs_cnst cursor local static for
    select name, object_id 
    	from sys.objects 
    	where parent_object_id = @objid 
    		and OBJECTPROPERTY(object_id, 'CnstIsDisabled') = 1 
    		and OBJECTPROPERTY(object_id, 'CnstIsNotRepl') = 0 
    		and (OBJECTPROPERTY(object_id, 'IsCheckCnst') = 1 
    			or OBJECTPROPERTY(object_id, 'IsForeignKey') = 1)
	union
    select name, object_id
    	from sys.triggers
    	where parent_id = @objid 
    		and OBJECTPROPERTY(object_id, 'IsTrigger') = 1 
        	and OBJECTPROPERTY(object_id, 'ExecIsTriggerNotForRepl') = 0 
        	and OBJECTPROPERTY(object_id, 'ExecIsTriggerDisabled') = 1
    for read only

    open ms_crs_cnst
    fetch ms_crs_cnst into @cnstname, @cnstid
    while @@fetch_status >= 0
    begin
        if(ObjectProperty(@cnstid, 'IsTrigger') = 1)
            select @enable_cmd = N'alter table ' + @dest + N' enable trigger ' + quotename(@cnstname)
        else
            select @enable_cmd = N'alter table ' + @dest + N' check constraint ' + quotename(@cnstname)

        execute(@enable_cmd)
        fetch ms_crs_cnst into @cnstname, @cnstid
    end     --of major loop
    deallocate ms_crs_cnst
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSreenable_check] TO [public] AS [dbo]
GO
