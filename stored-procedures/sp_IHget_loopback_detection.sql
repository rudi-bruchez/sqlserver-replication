SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHget_loopback_detection]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHget_loopback_detection] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHget_loopback_detection]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on

    DECLARE @retcode	 int
 
   -- Security check: Sysadmins and db_owners only
   exec @retcode = sys.sp_MSreplcheck_publish
   if @@error <> 0 or @retcode <> 0
   begin
      return 1
   end

   -- Has to be executed from distribution database
   if sys.fn_MSrepl_isdistdb (db_name()) != 1
   begin
      raiserror (21482, 16, -1, 'sp_IHget_loopback_detection', 'distribution')
      return 1
   end

    select distinct loopback_detection
    from 
    	MSsubscriptions s,
 		MSreplservers ss
    where 
    s.publisher_id =
		 (select srvid from MSreplservers
    	 where UPPER(srvname collate database_default) = UPPER(@publisher) collate database_default) and 
    s.publisher_db = @publisher_db and
    s.publication_id =
		 (select publication_id from MSpublications
	 	 where publisher_id = s.publisher_id and
               publisher_db = s.publisher_db and
               publication = @publication) and
    s.subscriber_db = @subscriber_db and
    s.subscriber_id = ss.srvid and
    UPPER(ss.srvname collate database_default) = UPPER(@subscriber) collate database_default and
    s.subscriber_id >= 0 
end
GO
GRANT EXECUTE ON [sys].[sp_IHget_loopback_detection] TO [public] AS [dbo]
GO
