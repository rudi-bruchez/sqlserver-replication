SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatelightweightprocstriggersconstraints]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatelightweightprocstriggersconstraints] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatelightweightprocstriggersconstraints]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@next_seed [bigint],
	@range [bigint],
	@threshold [int]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @retcode	int

	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1
    
	begin tran
	save tran sp_MSlightweightprocsandtriggers

	-- create the procedures
	exec @retcode= sys.sp_MScreatelightweightarticleprocs @pubid= @pubid, @artid= @artid
	if @@error <>0 or @retcode <> 0 goto Failure

	-- create the triggers if the article is updateable
	if 1 = sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)
	begin
		exec @retcode= sys.sp_MScreatelightweighttriggers @artid= @artid
		if @@error <>0 or @retcode <> 0 goto Failure
	end
	else
	begin
		-- Create trigger that disallows local updates/inserts/deletes.
		exec @retcode= sys.sp_MScreatedownloadonlytriggers @artid= @artid
		if @@error <> 0 or @retcode <> 0 goto Failure
	end

	-- set the identity range
	if @range is not null
	begin
		declare @objid int

		select @objid= objid from dbo.sysmergearticles where
			pubid = @pubid and artid = @artid
		if @objid is null goto Failure
		
		exec @retcode= sys.sp_MSreseed 
								@objid= @objid, 
								@next_seed= @next_seed,
								@range= @range
		if @@error <>0 or @retcode <> 0 goto Failure

		if not exists (select objid from dbo.MSmerge_idrange where objid = @objid)
		begin   
			insert into dbo.MSmerge_idrange	(objid, max_identity, range, threshold) 
									values (@objid, @next_seed + @range, @range, @threshold)
		end
		if @@error <>0 or @retcode <> 0 goto Failure
	end

	commit tran
	return 0

Failure:
	rollback tran sp_MSlightweightprocsandtriggers
	commit tran
	return 1
GO
GRANT EXECUTE ON [sys].[sp_MScreatelightweightprocstriggersconstraints] TO [public] AS [dbo]
GO
