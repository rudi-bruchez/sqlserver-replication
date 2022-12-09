SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_pub_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_pub_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_pub_identity]
	@publisher [sysname],
	@publisher_db [sysname],
	@tablename [sysname],
	@current_max [bigint] OUTPUT,
	@pub_range [bigint] OUTPUT,
	@threshold [int] OUTPUT,
	@range [bigint] OUTPUT,
	@next_seed [bigint] OUTPUT,
	@max_identity [bigint] OUTPUT
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

	if @current_max is not NULL
	begin
		select @current_max=current_max from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end

	if @max_identity is not NULL
	begin
		select @max_identity=max_identity from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end

	if @pub_range is not NULL
	begin
		select @pub_range=pub_range from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end

	if @threshold is not NULL
	begin
		select @threshold=threshold from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end
	if @next_seed is not NULL
	begin
		select @next_seed=next_seed from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end
	if @range is not NULL
	begin
		select @range=range from MSrepl_identity_range 
			where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
		if @@ERROR<>0	
			return (1)
	end

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_pub_identity] TO [public] AS [dbo]
GO
