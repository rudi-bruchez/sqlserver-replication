SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_validatemergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_validatemergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_validatemergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@level [tinyint]
WITH EXECUTE AS CALLER
AS
set nocount on 
	declare @retcode				int
	declare @pubid					uniqueidentifier
	declare @subid uniqueidentifier
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

	select @pubid = pubid from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
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

    select @subid = NULL
    select @subid = subid from dbo.sysmergesubscriptions where pubid=@pubid and db_name=@subscriber_db and 
	          UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
	if @subid is NULL
	begin
		raiserror(14055, 16, -1)
		return (1)
	end


	update dbo.MSmerge_replinfo 
	    set validation_level=@level 
	    where repid = @subid
	if @@ERROR<>0
		return (1)
	return (0)

GO
GRANT EXECUTE ON [sys].[sp_validatemergesubscription] TO [public] AS [dbo]
GO
