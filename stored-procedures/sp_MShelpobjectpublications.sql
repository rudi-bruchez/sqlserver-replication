SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpobjectpublications]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpobjectpublications] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpobjectpublications]
	@object_name [sysname]
WITH EXECUTE AS CALLER
AS
/*
	** Declarations.
	*/
	DECLARE @retcode                int
	DECLARE @mergepublish_bit       smallint
	DECLARE @transpublish_bit       int

	declare @object_id int

	/*
	** Security Check
	*/
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	/*
	** Initializations
	*/
	select @mergepublish_bit    = 4
	select @transpublish_bit    = 1
	select @object_id           = OBJECT_ID(@object_name)

	create table #helpobjpubs (
		publication     sysname         collate database_default not null, 
		reptype         int             NOT NULL, 
		article         sysname         collate database_default not null, 
		article_type    int             NULL, 
		column_tracking int             NULL, 
		article_resolver nvarchar(255)  collate database_default null,
		identity_support int            NULL, 
		resolver_clsid nvarchar(50)     NULL,
		resolver_info  nvarchar(517)    NULL,
		verify_resolver_signature int   NULL,
		allow_interactive_resolver bit  NULL,
		fast_multicol_updateproc bit    NULL,
		check_permissions int           NULL)
	/*
	**  1. Return the transactional publications that the table is involved in
	*/
	if (select category & @transpublish_bit from master.dbo.sysdatabases where name = DB_NAME() collate database_default) <> 0
	begin
		if exists (select * from sysextendedarticlesview a, 
			syspublications p where a.pubid = p.pubid and a.objid = @object_id)
			begin
				insert into #helpobjpubs(publication, reptype, article, article_type) 
					select p.name, 1, a.name, a.type  from sysextendedarticlesview a, 
						syspublications p where a.pubid = p.pubid and a.objid = @object_id
				IF @@ERROR <> 0 
					BEGIN
						select @retcode = 1
						goto DONE
					END
			end
	end
	/*
	**  2. Return the merge publications that the table is involved in
	*/
	if object_id('sysmergepublications') is not NULL
	begin
		if exists (select * from dbo.sysmergeextendedarticlesview a, 
			dbo.sysmergepublications p where a.pubid = p.pubid and a.objid = @object_id)
			begin
				insert into #helpobjpubs (publication, reptype, article, article_type, column_tracking, article_resolver,
				identity_support, resolver_clsid, resolver_info, verify_resolver_signature, allow_interactive_resolver,
							fast_multicol_updateproc, check_permissions)
					select p.name, 2, a.name, a.type, a.column_tracking, a.article_resolver, a.identity_support,
							a.resolver_clsid, a.resolver_info, a.verify_resolver_signature, a.allow_interactive_resolver,
							a.fast_multicol_updateproc, a.check_permissions
						from dbo.sysmergeextendedarticlesview a, dbo.sysmergepublications p 
						where a.pubid = p.pubid and a.objid = @object_id
				IF @@ERROR <> 0 
					BEGIN
						select @retcode = 1
						goto DONE
					END
			end
	end
	select @retcode = 0

DONE:
	select * from #helpobjpubs
	drop table #helpobjpubs
	return (@retcode)
GO
GRANT EXECUTE ON [sys].[sp_MShelpobjectpublications] TO [public] AS [dbo]
GO
