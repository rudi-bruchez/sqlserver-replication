SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_reinitmergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_reinitmergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_reinitmergepullsubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@upload_first [nvarchar](5)
WITH EXECUTE AS CALLER
AS
declare @schemaversion            int
    declare @schematype                smallint
    declare @schemaguid                uniqueidentifier
    declare @pubname                sysname
    declare @publisher_name            sysname
    declare @retcode                int
    declare @pubdb                    sysname
    declare @pubid                    uniqueidentifier
    declare @subid                    uniqueidentifier
    declare @artid                    uniqueidentifier
    declare @first_subscriber        bit
    declare @db_name                sysname

    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0 or @@error <> 0)
        return 1
    
    if LOWER(@upload_first collate SQL_Latin1_General_CP1_CS_AS) not in ('true', 'false')
    begin
        raiserror(14148, 16, -1, '@upload_first')
        return (1)
    end

    /*
    ** Replace 'all' with '%'
    */
    set nocount on
    if LOWER(@publication) = 'all'
        SELECT @publication = '%'

    if LOWER(@publisher) = 'all'
        SELECT @publisher = '%'

    if LOWER(@publisher_db) = 'all'
        SELECT @publisher_db = '%'

    select @retcode = 0

    /*
    ** At subscriber side, we need to qualify the publication with server name and database name
    */
    IF NOT EXISTS (SELECT * FROM dbo.sysmergepublications WHERE name LIKE @publication 
        and ((@publisher = N'%') or (UPPER(publisher) = UPPER(@publisher))) 
        and ((@publisher_db = N'%') or (publisher_db = @publisher_db)) )
        
    BEGIN
        IF @publication = '%'
                RAISERROR (14008, 11, -1)
        ELSE
                RAISERROR (20026, 11, -1, @publication)
        RETURN (1)
    END

	set @first_subscriber = 1
	
	Declare SYN_CUR CURSOR LOCAL FAST_FORWARD FOR 
		select subs.pubid, subs.subid, pubs.name, pubs.publisher, pubs.publisher_db
			from dbo.sysmergepublications pubs, dbo.sysmergesubscriptions subs
				where pubs.name LIKE  @publication
                    AND ((@publisher = '%') OR (UPPER(pubs.publisher) = UPPER(@publisher)))
                                        AND ((@publisher_db = N'%') OR (pubs.publisher_db = @publisher_db))
                    AND pubs.pubid=subs.pubid
                    AND subs.pubid<>subs.subid
                    AND (sys.fn_MSmerge_islocalsubid(subs.subid)=1)
                    AND (subs.subscription_type = 1 or subs.subscription_type = 2 or subs.subscription_type = 3) 
                    --only reinit pull/anonymous/light-weight subscriptions
    FOR READ ONLY

    open SYN_CUR
    fetch SYN_CUR into @pubid, @subid, @pubname, @publisher_name, @pubdb
    while (@@fetch_status<>-1)
    BEGIN    
        -- The following code only executes if there is at least one subscriber
        if @first_subscriber = 1
        begin
            -- 
            -- If it is the user's desire to reinitialize the pull subscriptions,
            -- we should make sure that new snapshots are delivered from scratch
            -- to this subscription database by resetting the snapshot delivery
            -- progress table.
            --
            exec @retcode = sys.sp_resetsnapshotdeliveryprogress 
            if @retcode <> 0 or @@error <> 0 return (1)

            set @first_subscriber=0
        end
    
        -- do not update schemaversion if the initial snapshot has never been applied.
        update dbo.sysmergesubscriptions set schemaversion=-1, recgen = NULL, recguid=NULL, 
            sentgen=NULL, sentguid = NULL where subid=@subid and schemaversion is not null

        if (@@rowcount <> 0)
        begin
        	if LOWER(@upload_first collate SQL_Latin1_General_CP1_CS_AS)='true'
        		update dbo.sysmergesubscriptions set status=5 where subid=@subid
        	else
        	begin
        		-- if they have previously requested reinit with upload first=true, status
				-- has been changed to 5. We have lost the info about the status before the 
				-- previous reinit. Use last_sync_status to determine whether the new status
				-- should be 0 or 1.
				update dbo.sysmergesubscriptions set status = 
					case when last_sync_status is null then 0 else 1 end
				where subid=@subid
				and status = 5
				
        		exec @retcode=sys.sp_MSCleanupForPullReinit @publication=@pubname,
                                        	  @publisher=@publisher_name,
                                        	  @publisher_db=@pubdb
                                      
        		if @retcode<>0 or @@ERROR<>0 return (1)
        	end
        end

		update dbo.sysmergesubscriptions 
			set recgen = NULL, recguid=NULL, sentgen=NULL, sentguid = NULL, replicastate= newid()
		where subid=@pubid and pubid=@pubid

        fetch next from SYN_CUR into @pubid, @subid, @pubname, @publisher_name, @pubdb	
        	-- so that it won't be treated as a new susbscription	
    END
    close SYN_CUR
    deallocate SYN_CUR

    -- If @first_subscriber is 1 then we didn't find any pull subscribers.
    if @first_subscriber = 1
    begin
        select @db_name = db_name()
        raiserror(21226,16,-1,@db_name)
        return 1
    end
    
    return 0
GO
GRANT EXECUTE ON [sys].[sp_reinitmergepullsubscription] TO [public] AS [dbo]
GO
