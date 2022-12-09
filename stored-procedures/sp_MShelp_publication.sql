SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_publication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare	@queued_agent sysname
    declare @retcode int
    declare @pubid int

    SELECT @retcode = 0

    /*
    ** Create a temp table of pubids identifying publications that the current user has access to
    */
    CREATE TABLE #accessiblepubs (pubid int)

    DECLARE hC  CURSOR LOCAL FAST_FORWARD FOR 
        SELECT publication_id FROM MSpublications WHERE ((@publication = N'%') or (publication = @publication))
    OPEN hC
    FETCH hC INTO @pubid
    WHILE (@@fetch_status <> -1)
    BEGIN
        IF is_member(N'db_owner') <> 1 AND isnull(is_member(N'replmonitor'),0) <> 1
        BEGIN
            exec @retcode = sys.sp_MScheck_pull_access
                @publication_id = @pubid,
                @raise_fatal_error = 0
	END			
        IF (is_member(N'db_owner') = 1) OR
           (isnull(is_member(N'replmonitor'),0) = 1) OR
           (@retcode = 0 AND @@error = 0)
           INSERT INTO #accessiblepubs values(@pubid)

        FETCH hC INTO @pubid
    END
    CLOSE hC
    DEALLOCATE hC

    if @publisher_db != '%' and @publication != '%' and not exists (select * from MSpublications where
        publisher_id = (select srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@publisher)) and
        ((@publisher_db = N'%') or (publisher_db = @publisher_db)) and
        publication = @publication)
    begin
        raiserror(20026, 16, -1, @publication)
        return(1)
    end

	select @queued_agent = name from MSqreader_agents 

	-- need to add new columns:
	-- num_subscriptions, num_now_syncing, num_errors, num_warning
	-- highest_perf_threshold, lowest_perf_threshold, 	
	--
	    declare @currentdate datetime
	    set @currentdate=getdate()

	declare @dymanic_info table(
		publication_id int primary key,
		num_subscriptions int,
		num_now_syncing int,
		num_errors int,
		num_warning int,
		merge_RunFastDurationThreshold int,
		merge_SyncExpireTimeThreshold int,
		WorstWarningDuration int,
		WorstWarningExpiration int
		);

		-- first we select all the values returned from the functions calls
		-- because other wise they will be called for every row maching the main query.
		insert into @dymanic_info 
		select p.publication_id,
		sys.fn_replgetNumMergesubscriptionsOnPublication(p.publisher_id, p.publisher_db, p.publication, p.publication_id) as num_subscriptions,
        sys.fn_replgetNumMergesubscriptionsNowSyncingOnPublication(p.publisher_id, p.publisher_db, p.publication, p.publication_id) as num_now_syncing,
        sys.fn_replgetNumOfErrorsMergesubscriptionsOnPublication(p.publisher_id, p.publisher_db, p.publication, p.publication_id) as num_errors,
        sys.fn_replgetNumOfWarningsMergesubscriptionsOnPublication(
        	p.publisher_id, 
        	p.publisher_db, 
        	p.publication, 
        	p.publication_id, 
        	p.retention,
            convert(int, sys.fn_replgetpublicationthreshold(p.publication_id, 4)),
        	convert(int, sys.fn_replgetpublicationthreshold(p.publication_id, 5)),
        	@currentdate
        ) as num_warning,
        convert(int, sys.fn_replgetpublicationthreshold(p.publication_id, 5))  as merge_RunFastDurationThreshold,
         sys.fn_replgetWorstWarningDurationMergesubscriptionsOnPublication(
        	p.publisher_id, 
        	p.publisher_db, 
        	p.publication, 
        	p.publication_id) as WorstWarningDuration,
        convert(int, sys.fn_replgetpublicationthreshold(p.publication_id, 4)) as merge_SyncExpireTimeThreshold,       
        sys.fn_replgetWorstWarningExpirationMergesubscriptionsOnPublication(
        	p.publisher_id, 
        	p.publisher_db, 
        	p.publication, 
        	p.publication_id, 
        	@currentdate) as WorstWarningExpiration    	
			from MSpublications p	
		where 
        p.publisher_id = (select srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@publisher)) 
		and ((@publisher_db = N'%') or (p.publisher_db = @publisher_db)) and   ((@publication = N'%') or (p.publication = @publication))

	


       select p.publisher_db as publisher_db, p.publication as publication, p.publication_id as publication_id, 
       p.publication_type as publication_type, 
        --thirdparty_flag, 
        independent_agent as independent_agent,
        immediate_sync as immediate_sync, allow_push as allow_push, 
        allow_pull as allow_pull, allow_anonymous as allow_anonymous, 'snapshot_agent' = s.name,
        'logreader_agent' = l.name, p.description as description, vendor_name as vendor_name
        -- queue reader agent only if we have valid queued subscription
        ,'queuereader agent' = case 
        	when (exists (select * from MSsubscriptions sub where sub.publisher_id = p.publisher_id and
						sub.publisher_db = p.publisher_db and sub.publication_id = p.publication_id and
						(sub.update_mode in (2,3,4,5,6,7)))) 
			then @queued_agent else NULL end
		,'thirdparty_options' = thirdparty_options
		,'snapshot_jobid' = j.job_id
        -- dynamic columns for repl monitor
        ,d.num_subscriptions as num_subscriptions
        ,d.num_now_syncing as num_now_syncing
        ,d.num_errors as num_errors
        ,d.num_warning as num_warning
        ,d.merge_RunFastDurationThreshold  as merge_RunFastDurationThreshold
        ,d.WorstWarningDuration as WorstWarningDuration
        ,d.merge_SyncExpireTimeThreshold as merge_SyncExpireTimeThreshold
        ,p.retention as retention
        ,d.WorstWarningExpiration as WorstWarningExpiration        
        from #accessiblepubs a
		JOIN @dymanic_info d
		ON
		d.publication_id = a.pubid 

        LEFT OUTER JOIN MSpublications p
        ON
        p.publication_id = a.pubid 
        LEFT OUTER JOIN MSsnapshot_agents s
        ON
        s.publisher_id = p.publisher_id and
        s.publisher_db = p.publisher_db and
        s.publication = p.publication
        LEFT OUTER JOIN MSlogreader_agents l
        ON
        (l.publisher_id = p.publisher_id and
        l.publisher_db = p.publisher_db and
        p.publication_type = 0 and              -- Only Transactional Publication has a  Log Reader
        (l.publication = p.publication OR
         thirdparty_flag = 0))
		LEFT OUTER JOIN msdb.dbo.sysjobs_view j
		ON
		s.job_id = j.job_id
      where 
        p.publisher_id = (select srvid from MSreplservers where UPPER(srvname collate database_default) = UPPER(@publisher)) and
        ((@publisher_db = N'%') or (p.publisher_db = @publisher_db)) and
       ((@publication = N'%') or (p.publication = @publication))
        order by p.publication
        
END
GO
GRANT EXECUTE ON [sys].[sp_MShelp_publication] TO [public] AS [dbo]
GO
