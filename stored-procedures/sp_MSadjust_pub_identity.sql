SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadjust_pub_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadjust_pub_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadjust_pub_identity]
	@publisher [sysname],
	@publisher_db [sysname],
	@tablename [sysname],
	@current_max [bigint],
	@threshold [int],
	@range [bigint],
	@next_seed [bigint],
	@pub_range [bigint]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode		int
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
		raiserror(21482, 16, -1, 'sp_MSadjust_pub_identity', 'distribution')
		return (1)
	end
	if @current_max is NOT NULL
	begin
		update MSrepl_identity_range set current_max=@current_max 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
		if exists (select * from MSrepl_identity_range where max_identity is not NULL 
			and ABS(current_max) > ABS(max_identity))
		begin
			raiserror(21195, 16, -1)
			return (1)
		end
	end
	if @threshold is NOT NULL
	begin
		update MSrepl_identity_range set threshold=@threshold 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end
	if @next_seed is NOT NULL
	begin
		update MSrepl_identity_range set next_seed=@next_seed 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0
			return (1)
	end
	if @range is NOT NULL
	begin
		update MSrepl_identity_range set range=@range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db	
		if @@ERROR<>0
			return (1)
	end
	if @pub_range is NOT NULL
	begin
		update MSrepl_identity_range set pub_range=@pub_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db	
		if @@ERROR<>0
			return (1)
	end

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadjust_pub_identity] TO [public] AS [dbo]
GO
