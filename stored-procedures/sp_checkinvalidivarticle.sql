SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_checkinvalidivarticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_checkinvalidivarticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_checkinvalidivarticle]
	@mode [tinyint],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on 
	
	if @mode = 0
	begin 
		IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0) AND
		(ISNULL(IS_SRVROLEMEMBER('dbcreator'),0) = 0) AND
		(ISNULL(IS_MEMBER('db_owner'),0) = 0)
		BEGIN
			RAISERROR(18799, 16, -1) 
			RETURN (1)
		END
	end
	
	declare @artname nvarchar(524)
				,@objname nvarchar(524)
				,@pubname nvarchar(524)
				,@object_id int
				,@result int
				
    -- Only attempt to get an application lock if the caller is 
    -- db_owner as the intention of the lock is for coordinating between
    -- the snapshot agent (db_owner) and ddl replication (requires db_owner
    -- via sp_MSprep_exclusive)
    IF (@mode = 1 and (is_member(N'db_owner') = 1))
    BEGIN
    EXEC @result = sys.sp_getapplock @Resource = @publication, 
                @LockMode = N'Shared', 
                @LockOwner = N'Session', 
                @LockTimeout = 0,
                @DbPrincipal = N'db_owner' -- Note that we already require db_owner because of security check performed at the beginning of the procedure
	    IF @result < 0
	    BEGIN
	        RAISERROR(21385, 16, -1, @publication)
	        RETURN (1)
	    END
    END
				
	declare #hlogbasedarticles cursor local fast_forward for
		select distinct a.name, object_name(a.objid), p.name, a.objid
		from dbo.sysarticles a join dbo.syspublications p on a.pubid = p.pubid
			join syssubscriptions s on s.artid = a.artid 
		where objectproperty(objid, 'IsView') = 1 
			and ((@mode = 1 and p.name = @publication) --snapshot mode
				or (@mode = 0 and s.status in (2, 3)))-- 0 inactive, 1 subscribed, 2 active, 3 initiated

	open #hlogbasedarticles
	fetch #hlogbasedarticles into @artname, @objname, @pubname, @object_id

	while (@@fetch_status <> -1)
	begin			
		-- log-based iv article needs to have active cl index 
		if not exists(select * from sys.indexes where object_id = @object_id 
			and index_id = 1 and is_disabled = 0)
		begin 
			if (@mode = 0) 
			begin 
				raiserror (21857, 10, 1, @artname, @pubname, @objname)
				exec sys.sp_MSreinit_article 
					@publication = @pubname
					,@article = @artname
					,@need_new_snapshot = 1
					,@need_reinit_subscription = 1
					,@force_invalidate_snapshot = 1
					,@force_reinit_subscription = 1
					,@ignore_distributor_failure = 1 -- in case distribtor is not up, we don't want to fail upgrade
			end
			else if(@mode = 1)
			begin
				raiserror (21858, 16, 1, @artname, @pubname, @objname)
			end
		end
		fetch #hlogbasedarticles into @artname, @objname, @pubname, @object_id
	end
	close #hlogbasedarticles 
	deallocate #hlogbasedarticles    
	IF (@mode = 1 and (is_member(N'db_owner') = 1))
    BEGIN
        EXEC sys.sp_releaseapplock @Resource = @publication, @LockOwner = N'Session', @DbPrincipal = N'db_owner'
    END
	return 0
end    
GO
GRANT EXECUTE ON [sys].[sp_checkinvalidivarticle] TO [public] AS [dbo]
GO
