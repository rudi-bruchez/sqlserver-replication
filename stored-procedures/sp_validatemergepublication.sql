SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validatemergepublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validatemergepublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validatemergepublication]
	@publication [sysname],
	@level [tinyint]
WITH EXECUTE AS CALLER
AS
set nocount on 
	declare @artid					uniqueidentifier
	declare @schematype				int
	declare @schemaversion			int
	declare @schemaguid				uniqueidentifier
	declare @schematext				nvarchar
	declare @retcode				int
	declare @pubid					uniqueidentifier
	declare @compatlevel int
	
	/*
	** Security Check
	*/
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
		return (1)

	/* make sure current database is enabled for merge replication */
	exec @retcode=sys.sp_MSCheckmergereplication
	if @@ERROR<>0 or @retcode<>0
		return (1)

	select @pubid = pubid, @compatlevel = backward_comp_level from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
	if @pubid is NULL
	begin
		raiserror (20026, 16, -1, @publication)
		return (1)
	end
	if @level <1 or @level > 3
	begin
		raiserror(21184, 16, -1, '@level', '1', '2','3')
		return (1)
	end

    if @compatlevel < 30
    begin
    	raiserror(21356, 10, -1, @publication)
    	exec @retcode=sys.sp_MSBumpupCompLevel @pubid, 30 
    	if @@ERROR<>0 or @retcode<>0		
    		return (1)
    end
    
	select @schemaversion = schemaversion from dbo.sysmergeschemachange
	if (@schemaversion is NULL)
		set @schemaversion = 1
	else
		select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
		set @schemaguid = newid()
		set @artid = newid()
		set @schematype = 66 /* publication wide validation */
		select @schematext = convert(nvarchar, @level)		
		exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
		if @@ERROR<>0 or @retcode<>0
			return (1)
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_validatemergepublication] TO [public] AS [dbo]
GO
