SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfetchAdjustidentityrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfetchAdjustidentityrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfetchAdjustidentityrange]
	@publisher [sysname],
	@publisher_db [sysname],
	@tablename [sysname],
	@adjust_only [bit],
	@for_publisher [tinyint],
	@range [bigint] OUTPUT,
	@next_seed [bigint] OUTPUT,
	@threshold [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@got_access bit
				,@publisher_id int
				,@publication_id int

    --
    -- Do we have entry for the table
    --
    if not exists (select * from dbo.MSrepl_identity_range
        where  tablename=@tablename and LOWER(publisher)=LOWER(@publisher) 
            and publisher_db=@publisher_db)
    begin
        RAISERROR (15021, 16, -1, '@publisher, @publisher_db or @tablename')
        return (1)
    end
    --
    -- security check
    --
    if (is_member ('db_owner') != 1) and (is_srvrolemember('sysadmin') != 1) 
    begin
        -- do PAL check for any publication that contains an article for this table
        SELECT @publisher_id = srvid 
        FROM MSreplservers
        WHERE UPPER(@publisher) = UPPER(srvname)  
        IF @publisher_id IS  NULL
        BEGIN
            RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
        END
        if not exists (select publication_id from dbo.MSarticles where 
            publisher_id = @publisher_id and
            publisher_db = @publisher_db and 
            source_object = @tablename)
        begin
            raiserror (20026, 11, -1, 'any')
            return (1)
        end

		declare #publications_cursor CURSOR LOCAL FAST_FORWARD for
			select distinct publication_id from dbo.MSarticles 
			where publisher_id = @publisher_id 
				and publisher_db = @publisher_db
				and source_object = @tablename

		select @got_access = 0
		open #publications_cursor
		fetch #publications_cursor into @publication_id
		while (@@fetch_status <> -1)
		begin
			exec @retcode = sys.sp_MScheck_pull_access
				@agent_type = 0, -- tran agent
				@publication_id = @publication_id
			if (@retcode = 0 and @got_access = 0)
			begin
				select @got_access = 1
				break
			end
			fetch #publications_cursor into @publication_id
		end
		close #publications_cursor
		deallocate #publications_cursor
		-- do not have PAL access to any publication that contains this table
		if @got_access = 0
		begin
			RAISERROR (15247, 11, -1)
			return (1)
		end
	end
	--
	-- Continue processing
	--
	if @adjust_only=0
		select identity_support, next_seed, range, threshold from dbo.MSrepl_identity_range
		where  tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
	--
	-- Note: there might be multiple sessions calling this sp at the same time
	-- Open a transaction so that the update row will be locked so that no one else can
	-- process this row.
	--
	begin tran
	save TRAN sp_MSfetchAdjustidentityrange

	if @for_publisher=2 --republishing scenario
	begin
		update dbo.MSrepl_identity_range set max_identity=@next_seed + @range, next_seed=@next_seed
		where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
	end
	else
	begin    
		update dbo.MSrepl_identity_range set next_seed = case @for_publisher
			-- use subscriber's range 
			when 0 then next_seed + range
			-- use @range sent in by the publisher
			else next_seed + @range
			end
		where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db
	end

	-- for tran pub, max_identity could be null for Shiloh publisher
	if @@ERROR<>0 OR exists (select * from MSrepl_identity_range where max_identity is not null and ABS(next_seed)>ABS(max_identity))
	begin
		raiserror(21195, 16, -1)
		goto UNDO
	end

	select @next_seed = next_seed, @range = range, @threshold = threshold from dbo.MSrepl_identity_range
	where tablename=@tablename and LOWER(publisher)=LOWER(@publisher) and publisher_db=@publisher_db

	commit tran
	return 0

UNDO:
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRAN sp_MSfetchAdjustidentityrange
		COMMIT TRAN
	end
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSfetchAdjustidentityrange] TO [public] AS [dbo]
GO
