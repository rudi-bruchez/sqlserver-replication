SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdropobsoletearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdropobsoletearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdropobsoletearticle]
	@artid [int],
	@ignore_distributor [bit],
	@force_invalidate_snapshot [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int = 0
	declare @article sysname
	declare @publication sysname

	-- security check - should be dbo or sysadmin
	exec @retcode = sp_MSreplcheck_publish_withddladmin
	if @@ERROR != 0 or @retcode != 0 return 1

	select top 1 @article = sa.name, @publication = sp.name
		from sysarticles sa join syspublications sp on sa.pubid = sp.pubid
		where sp.options & 0x80 = 0x80 and sa.objid is not null and object_name(sa.objid) is null and (sa.artid = @artid or @artid is null)
	while @@rowcount = 1 and @retcode = 0 begin
		exec @retcode = sp_dropsubscription @publication = @publication, @article = @article, @subscriber = 'all', @ignore_distributor = @ignore_distributor
		if @retcode <> 0 break
		exec @retcode = sp_droparticle @publication = @publication, @article = @article, @force_invalidate_snapshot = @force_invalidate_snapshot, @ignore_distributor = @ignore_distributor
		select top 1 @article = sa.name, @publication = sp.name
			from sysarticles sa join syspublications sp on sa.pubid = sp.pubid
			where sp.options & 0x80 = 0x80 and sa.objid is not null and object_name(sa.objid) is null and (sa.artid = @artid or @artid is null)
	end
		
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSdropobsoletearticle] TO [public] AS [dbo]
GO
