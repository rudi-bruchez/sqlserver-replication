SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddsubscriptionarticles]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddsubscriptionarticles] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddsubscriptionarticles]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@artid [int],
	@article [sysname],
	@dest_table [sysname],
	@dest_owner [sysname]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode 	bit,
			@agent_id 	int,
			@object_id	int,
			@ident_col	sysname,
			@qualifiedname nvarchar(600)
	
	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or @retcode <> 0 
    begin
        return 1
    end

	select @agent_id = id
		from MSsubscription_agents
		where publisher = @publisher
			and publisher_db = @publisher_db
			and publication = @publication
	if @@error <> 0
		or @agent_id is NULL
	begin
		-- Could not find a valid Agent Id for the subscription to Publisher @publisher, database @publisher_db, publication @publication.
		raiserror(21758, 16, -1, @publisher, @publisher_db, @publication)
		return 1
	end

	-- if the entry already exists then we will just exit
	-- note that we do not check the @artid... this is 
	-- because the value has no meaning to us and we only
	-- need to match on the article, object and agentid
	if exists (select * 
					from MSsubscription_articles
					where agent_id = @agent_id
			            and article = @article
			            and dest_table = @dest_table
			            and owner = @dest_owner)
	begin
		return 0
	end
	
	begin transaction tran_addsubscriparticles
	save transaction tran_addsubscriparticles
	
	insert into MSsubscription_articles
        (
            agent_id,	-- related entry in MSsubscription_agents
            artid,		-- article id
            article,	-- article name
            dest_table,	-- destination table
            owner		-- destination owner
        )
        values
        (
        	@agent_id,
			@artid,
		    @article,
		    @dest_table,
		    @dest_owner
        )
	if @@error <> 0
	begin
		-- The procedure sys.sp_MSaddsubscriptionarticles failed to INSERT into the resource MSsubscription_articles. Server error =  0.
		raiserror (21499, 16, -1, 'sys.sp_MSaddsubscriptionarticles', 'INSERT into', 'MSsubscription_articles.', @@error)
		goto FAILURE
	end

	select @qualifiedname = quotename(@dest_owner) + '.' + quotename(@dest_table)

	-- For user tables we will also want to set NFR for identity cols
	select @object_id = object_id(@qualifiedname, N'U')

	if @object_id is not NULL
	begin		
		select @ident_col = name
			from sys.columns 
			where object_id = @object_id 
				and ColumnProperty(object_id, name, 'IsIdentity') = 1
				and ColumnProperty(object_id, name, 'IsIdNotForRepl') =  0

		if @ident_col is not NULL
		begin
			
			exec %%Object(MultiName = @qualifiedname).LockMatchID(ID = @object_id, Exclusive = 1, BindInternal = 0)
			if (@@ERROR != 0)
				goto FAILURE

			exec %%ColumnEx(ObjectID = @object_id, Name = @ident_col).SetIdentityNotForRepl(Value = 1)
		end
	end
	
	commit transaction tran_addsubscriparticles
	
	return 0
FAILURE:
	rollback transaction tran_addsubscriparticles
	commit transaction tran_addsubscriparticles
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSaddsubscriptionarticles] TO [public] AS [dbo]
GO
