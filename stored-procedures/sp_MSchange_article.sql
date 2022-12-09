SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_article]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_article] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_article]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@article_id [int],
	@property [nvarchar](20),
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @retcode int
	DECLARE @publisher_id smallint
	DECLARE @publication_id int
	declare @tablename sysname

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
		raiserror(21482, 16, -1, 'sp_MSchange_article', 'distribution')
		return (1)
	end

	-- Get publisher id

	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	-- lower case property
	select @property = lower (@property)
	
	-- Get publication id

	select @publication_id = publication_id
		from dbo.MSpublications where
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db and
		publication = @publication
	if @publication_id is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end

	if @property = N'description'     
	begin
		update MSarticles set description = @value
		where publisher_id = @publisher_id
		and publisher_db = @publisher_db
		and publication_id = @publication_id
		and article = @article
		and article_id = @article_id
		if @@error <> 0
		begin
			return 1
		end
	end
	else if @property in( N'dest_table', N'dest_object' )
	begin
		update MSarticles set destination_object = @value
		where publisher_id = @publisher_id
		and publisher_db = @publisher_db
		and publication_id = @publication_id
		and article = @article
		and article_id = @article_id
		if @@error <> 0
		begin
			return 1
		end
	end
	else if @property = 'identity_range'
	begin
		declare @range bigint
		select @range = convert(bigint, @value)
		select @tablename = source_object from MSarticles 
			where publisher_id = @publisher_id
			and publisher_db = @publisher_db
			and publication_id = @publication_id
			and article = @article
			and article_id = @article_id

		update MSrepl_identity_range set range = @range where
			publisher = @publisher and
			publisher_db = @publisher_db and
			tablename = @tablename
		if @@error <> 0
		begin
			return 1
		end
	end
	else if @property = 'threshold'
	begin
		declare @threshold int
		select @threshold = convert(int, @value)
		select @tablename = source_object from MSarticles 
			where publisher_id = @publisher_id
			and publisher_db = @publisher_db
			and publication_id = @publication_id
			and article = @article
			and article_id = @article_id

		update MSrepl_identity_range set threshold = @threshold where
			publisher = @publisher and
			publisher_db = @publisher_db and
			tablename = @tablename
		if @@error <> 0
		begin
			return 1
		end
	end
	else if @property in ('destination_owner', 'dest_owner')
	begin
		update MSarticles
			set destination_owner = @value
			where publisher_id = @publisher_id
				and publisher_db = @publisher_db
				and publication_id = @publication_id
				and article = @article
				and article_id = @article_id
		if @@error <> 0
		begin
			return 1
		end
	end
	else
	begin
		return 1
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MSchange_article] TO [public] AS [dbo]
GO
