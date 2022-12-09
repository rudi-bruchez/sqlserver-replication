SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinsert_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinsert_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinsert_identity]
	@publisher [sysname],
	@publisher_db [sysname],
	@tablename [sysname],
	@identity_support [int],
	@pub_identity_range [bigint],
	@identity_range [bigint],
	@threshold [int],
	@next_seed [bigint],
	@max_identity [bigint]
WITH EXECUTE AS CALLER
AS
begin
	declare @pub_seed 		bigint	
	declare @current_max 	bigint
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSinsert_identity', 'distribution')
		return (1)
	end
	if not exists (select * from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db)
	begin
		select @pub_seed = @pub_identity_range + @next_seed
		select @current_max = @pub_seed - 1
		insert MSrepl_identity_range(publisher, publisher_db, tablename, identity_support, next_seed, pub_range, range, max_identity, threshold, current_max	)
				values (@publisher, @publisher_db, @tablename, @identity_support, @pub_seed,  @pub_identity_range, @identity_range, @max_identity, @threshold, @current_max)
		if @@ERROR<>0
			return 1
	end
	else if 1 > 1 --disable this segment for now.
		begin --adjust republisher's resource table
			select @pub_seed = @pub_identity_range - 1
			/* update range, threshold at republisher as needed. Max and next_seed has been set already. */
			update MSrepl_identity_range set	range = @identity_range,
												pub_range = @pub_identity_range,
												threshold=@threshold, 
												next_seed=next_seed + @pub_identity_range,
												current_max=next_seed + @pub_seed --new next_seed not yet picked up
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
			if @@ERROR<>0
				return (1)
		end
end
GO
GRANT EXECUTE ON [sys].[sp_MSinsert_identity] TO [public] AS [dbo]
GO
