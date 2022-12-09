SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_dropobject]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_dropobject] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_dropobject]
	@objid [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int

	if exists (SELECT * FROM dbo.sysextendedarticlesview WHERE objid = @objid)
	begin
		--  Security Check
		EXEC @retcode = sys.sp_MSreplcheck_publish
		IF @@ERROR <> 0 or @retcode <> 0
			return 1
	end

	-- Look for the replication articles, referring to a subject table, whose publication doesn't have
	-- @OPT_ALLOW_DROP = 0x80 bit set, what should block drop of subject table.
	-- Keep shared locks to avoid add of new articles and possible changes to publication options during drop table.
	select @retcode = count(*) from sysarticles sa with(HOLDLOCK)
	join syspublications sp with(HOLDLOCK) on sa.pubid = sp.pubid and sa.objid = @objid and (sp.options & 0x80) <> 0x80

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_dropobject] TO [public] AS [dbo]
GO
