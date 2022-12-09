SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddanonymousreplica]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddanonymousreplica] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddanonymousreplica]
	@publication [sysname],
	@publisher [sysname],
	@publisherDB [sysname],
	@anonymous [int],
	@sync_type [int],
	@preexists [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on
declare @retcode                 int
declare @subscription_type         nvarchar(15)
declare @sync_typestr             nvarchar(15)
declare @sub_typeid                int
declare @pubid                    uniqueidentifier

/*
** need more than PAL to do this since this is run at the subscriber site
*/
exec @retcode = sp_MSreplcheck_subscribe
if @@error<>0 or @retcode<>0
begin
        RAISERROR (14126, 11, -1)
       return 1
end

select @preexists = 0

select @subscription_type = 'default'

if @anonymous = 1 
begin
    select @subscription_type = 'anonymous'
    select @sub_typeid    = 2 --subscription type value for anonymous
end
else if @anonymous = 2
begin
    select @subscription_type = 'lightweight'
    select @sub_typeid = 3 --subscription type value for lightweight
end
else
begin
    select @subscription_type = 'local'
    select @sub_typeid = 1 --subscription type value for well known pull
end

if @sync_type = 1 select @sync_typestr = 'automatic'
    else select @sync_typestr = 'none'

-- Get publisher port number
declare @publisher_with_port sysname
exec sys.sp_MSget_server_portinfo 
    @name = @publisher, 
    @srvname = @publisher OUTPUT,
    @srvname_with_port = @publisher_with_port OUTPUT

-- this change is made so that we will try to add pull/anonymous subscriptions, even if
-- there is a already a subscription for that publication, however the subscription type
-- does not match. In this way we can prevent users from using incorrect subscription type
-- through command line or merge control. 
if object_id('sysmergepublications') is not NULL
begin
    select @pubid=pubid from dbo.sysmergepublications 
        where name=@publication and UPPER(publisher)=UPPER(@publisher) and publisher_db = @publisherDB

    if @pubid is not NULL
    begin
        /* Check if theres is a subscriptions entry that matches the pubid and current subscription with the right type */
        if exists (select * from dbo.sysmergesubscriptions where pubid =@pubid  and UPPER(subscriber_server) = @@SERVERNAME and db_name = DB_NAME() and subscription_type=@sub_typeid)
        begin
            select @preexists = 1
            return (0)   -- replica exists. 
        end
        /* 
        ** Check if theres is a subscriptions entry that matches the pubid and current subscription - 
        ** If there is a match and the types are not the same, then return appropriate error.
        */
        else if exists (select * from dbo.sysmergesubscriptions where pubid =@pubid  and UPPER(subscriber_server) = @@SERVERNAME and db_name = DB_NAME())
        begin
            RAISERROR (21500, 16, -1, @publication)    
            -- replica exists with wrong subscription type 
            select @preexists = 1

            return (1)   
        end
    end
end

-- Call this SP to add this replica
exec @retcode = sys.sp_addmergepullsubscription 
    @publication = @publication,
    @publisher = @publisher_with_port,
    @publisher_db=@publisherDB,
    @subscriber_type =@subscription_type,
    @sync_type = @sync_typestr
IF @retcode<>0 or @@ERROR<>0 return (1)
return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSaddanonymousreplica] TO [public] AS [dbo]
GO
