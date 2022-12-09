SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpconflictpublications]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpconflictpublications] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpconflictpublications]
	@publication_type [varchar](9)
WITH EXECUTE AS CALLER
AS
BEGIN
	SET nocount ON
	declare @retcode int
				,@fcheckpal bit

	--
	-- Decide if we need PAL security check - If sysadmin or dbo - skip PAL check
	--
	select @fcheckpal = case when  ((is_srvrolemember('sysadmin') = 1) or (is_member ('db_owner') = 1)) 
											   then 0 else 1 end
	--
	-- validate publication type
	--
	IF NOT( lower(@publication_type collate SQL_Latin1_General_CP1_CS_AS) IN ('%', 'merge', 'queued', 'p2p') )
	BEGIN
		raiserror( 'invalid publication type', 16, -1 )
		RETURN (1)
	END
	-- temp table to store combined result set
	CREATE TABLE #result_list ( publication sysname collate database_default, publication_type VARCHAR(9) DEFAULT 'merge', 
			merge_pub_id UNIQUEIDENTIFIER NULL, 
			queued_pub_id INTEGER NULL, sub_agent_id INTEGER NULL, 
			publisher sysname collate database_default NULL, 
			publisher_db sysname collate database_default NULL,
			hasaccess bit not null default 1)
	--
	-- process according to publication type
	--
	IF ( lower(@publication_type collate SQL_Latin1_General_CP1_CS_AS) IN ('%', 'merge') )
	BEGIN
		--
		-- fetch merge results into temp table; need not affect any rows
		--
		IF EXISTS( SELECT * from sys.objects WHERE name = 'sysmergepublications' )
			INSERT #result_list ( publication, merge_pub_id, publisher, publisher_db)
				EXEC @retcode = sys.sp_MShelpmergeconflictpublications
		--
		-- may return 18757 (not merge published) and that is ok if @publication_type = ALL
		--
		IF ( @retcode <> 0 AND @@ERROR <> 0) AND ( @@ERROR = 18757 AND @publication_type = '%' ) 
			GOTO FAILURE
	END
	IF ( lower(@publication_type collate SQL_Latin1_General_CP1_CS_AS) IN ('%', 'queued', 'p2p') )
	BEGIN
		--
		-- fetch tran results into temp table
		--
		INSERT #result_list  ( publication, publication_type, merge_pub_id , queued_pub_id, sub_agent_id )
			EXEC @retcode = sys.sp_MShelptranconflictpublications @publication_type = '%'
		IF ( @retcode <> 0 AND @@ERROR <> 0) 
			GOTO FAILURE
	END
	--
	-- PAL check related processing
	--
	if (@fcheckpal = 1)
	begin
		--
		-- check for PAL for each publication
		--
		declare @publication sysname
					,@pubtype sysname
					,@mergepubid uniqueidentifier
					,@tranpubid int
		declare #hc  cursor local fast_forward for 
			select publication, publication_type,  merge_pub_id, queued_pub_id
			from #result_list 
		open #hc
		fetch #hc into @publication, @pubtype, @mergepubid, @tranpubid
		while (@@fetch_status <> -1)
		begin
			if (@pubtype = 'merge')
			begin
				if ({fn ISPALUSER(@mergepubid)} != 1)
				begin
					--
					-- no access for this publication
					--
					update #result_list set hasaccess = 0 
					where merge_pub_id = @mergepubid
				end
			end
			else if (@pubtype in ('queued', 'p2p'))
			begin
				--
				-- tran specific PAL check
				--
				exec @retcode = sp_MSreplcheck_pull
						@publication = @publication,
						@raise_fatal_error = 0
				 if (@@error != 0) or (@retcode != 0)
				begin
					--
					-- no access for this publication
					--
					update #result_list set hasaccess = 0 
					where queued_pub_id = @tranpubid
				end
			end
			--
			-- get next publication
			--
			fetch #hc into @publication, @pubtype, @mergepubid, @tranpubid
		end
		close #hc
		deallocate #hc
	end
	--
	-- return combined result list where access is set
	--
	select publication, publication_type, merge_pub_id, queued_pub_id
		,sub_agent_id, publisher, publisher_db
	from #result_list 
	where hasaccess = 1
	--
	-- all done
	--
	RETURN (0)

FAILURE:
	IF EXISTS( SELECT * FROM sys.objects WHERE type = 'U' AND name = '#result_list' )
		DROP TABLE #result_list
	RETURN (1)    
END
GO
GRANT EXECUTE ON [sys].[sp_MShelpconflictpublications] TO [public] AS [dbo]
GO
