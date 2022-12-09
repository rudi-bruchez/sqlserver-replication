SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetalternaterecgens]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetalternaterecgens] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetalternaterecgens]
	@repid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode                        int
        declare @publisher              sysname
        declare @publisher_db   sysname
        declare @publication    sysname
        
        /*
        ** do permission checking
        */
        exec @retcode = sys.sp_MSrepl_PAL_rolecheck @repid = @repid
        if @retcode<>0 or @@ERROR<>0 
            return (1)

        select @publisher= publisher, @publisher_db= publisher_db, @publication= name
                from dbo.sysmergepublications
                where pubid = @repid

    select distinct p.pubid as altpubid, s.recguid as recguid, s.recgen as recgen
    from dbo.sysmergesubscriptions s, dbo.sysmergepublications p, dbo.MSmerge_altsyncpartners alt
    where (p.pubid = alt.subid or p.pubid = alt.alternate_subid) and
          p.pubid <> @repid and
          upper(s.subscriber_server collate SQL_Latin1_General_CP1_CS_AS) = upper(p.publisher collate SQL_Latin1_General_CP1_CS_AS) and
          s.db_name = p.publisher_db and
                  s.pubid = @repid
         and s.recguid is not null and s.recgen is not null
        return @retcode 
GO
GRANT EXECUTE ON [sys].[sp_MSgetalternaterecgens] TO [public] AS [dbo]
GO
