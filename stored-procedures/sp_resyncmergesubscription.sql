SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_resyncmergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_resyncmergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_resyncmergesubscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@resync_type [int],
	@resync_date_str [nvarchar](30)
WITH EXECUTE AS CALLER
AS
declare @retcode             int
    declare @subid                uniqueidentifier
    declare @pubid                uniqueidentifier
    declare @subscriber_srvid     int
    declare @resync_gen            bigint
    declare @smallest_open_gen        bigint
    declare @resync_date        datetime
    /*
    ** Security Check
    */

    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

	-- @resyn_date_str needs to be specified when @resync_type is 2
	if (@resync_date_str is NULL) and (@resync_type = 2)
    begin
        raiserror(22552, 16, -1)
        return (1)
    end
	
    if isdate(@resync_date_str)=0 and @resync_type=2
    begin
        raiserror(21370, 16, -1, @resync_date_str)
        return (1)
    end
    if @resync_date_str is not NULL
        select @resync_date=convert(datetime, @resync_date_str)
    else
        select @resync_date = NULl
    
    /*
    ** parameter checking for null/not-null; including validity of @resync_type and @resync_date
    */

    if ((@publisher is NULL and @subscriber is NULL) or
       (@publisher is not NULL and @subscriber is not NULL) or
       (@publisher is NULL and @publisher_db is not NULL) or
       (@subscriber is NULL and @subscriber_db is not NULL) or
       (@publisher is not NULL and @publisher_db is NULL) or
       (@subscriber is not NULL and @subscriber_db is NULL))
       begin
               raiserror(21294, 16, -1)
               return (1)
       end

    if @resync_type<0 or @resync_type>2
        begin
            raiserror(21296, 16, -1)
            return (1)
        end

    if @publisher is NULL    
        select @publisher=publishingservername()
    if @publisher_db is NULL
        select @publisher_db=db_name()
    if @subscriber is NULL
        select @subscriber=@@SERVERNAME
    if @subscriber_db is NULL
        select @subscriber_db=db_name()
        
    select @pubid = pubid from dbo.sysmergepublications where name=@publication and lower(publisher)=lower(@publisher) and publisher_db=@publisher_db
    if (@pubid is null)
        begin
            RAISERROR (20026, 16, -1, @publication)
            return (1)
        end
    select @subid=subid from dbo.sysmergesubscriptions 
        where pubid=@pubid and LOWER(subscriber_server)=LOWER(@subscriber) and db_name=@subscriber_db
    if @resync_type > 0 --since a given date or last validation    
    begin
        if @resync_type = 1    -- last validation time; make sure resync_date is not NULL in this case; 
        begin
            select @resync_date=last_validated from dbo.sysmergesubscriptions where subid=@subid
            -- invalid case - there is no prior validation, this call is a non-op.
            if @resync_date is NULL
            begin
                raiserror(22553, 16, -1, @resync_type)
                return (1)
            end
        end
        
        select @resync_gen=NULL
        select top 1 @resync_gen=generation from dbo.MSmerge_genhistory 
            where  coldate > @resync_date 
                    and art_nick in (select nickname from dbo.sysmergearticles where pubid=@pubid)
                    and genstatus in (1,2)
                order by coldate ASC
        -- this is valid case, meaning there is no need to do any resynchronization
        if @resync_gen is NULL
        begin
            return (0)
        end

        -- We can not set the resync_gen to be larger than a open generation so do the following to
        -- verify that we don't.
        -- Make sure that there aren't any open generations below the resyn_gen we have picked.
        -- Following query finds the smallest open generation below the resyn_gen we have picked.
        select @smallest_open_gen = NULL
        select top 1 @smallest_open_gen = generation from dbo.MSmerge_genhistory
            where    generation < @resync_gen
                and  genstatus in (0, 4)
            order by generation ASC

        -- If there exists a open generation with generation values lower than resync_gen then
        -- set resync_gen to the highest closed generation below the open generation.
        if (@smallest_open_gen is not NULL)
        begin
          select @resync_gen=NULL
            select top 1 @resync_gen = generation from dbo.MSmerge_genhistory
                where generation < @smallest_open_gen
                    and genstatus in (1,2)
                order by generation DESC
                
            if (@resync_gen is NULL)
                select @resync_gen = 0                            
        end                                        
    end
    else if @resync_type=0
        select @resync_gen=0 -- force convergence case
    update  dbo.MSmerge_replinfo  set resync_gen=@resync_gen where repid=@subid
    if @@ERROR<>0
        begin
            raiserror(21298, 16, -1)
            return (1)
        end
GO
GRANT EXECUTE ON [sys].[sp_resyncmergesubscription] TO [public] AS [dbo]
GO
