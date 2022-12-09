SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSretrieve_publication_attributes]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSretrieve_publication_attributes] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSretrieve_publication_attributes]
	@name [sysname],
	@database [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

declare @mergepublish_bit    int
declare @tranpublish_bit    int
declare @procname            nvarchar(640)
declare @retcode            int

select @mergepublish_bit    = 4 
select @tranpublish_bit     = 1

/*
** Security Check, will be checked inside sp_MSretrieve_publication
** and sp_MSretrieve_mergepublication
*/

create table #publication_property (
    Name                     sysname collate database_default,
    dbname                    sysname collate database_default,
    Publisher                sysname collate database_default,
    Type                    nvarchar(15) collate database_default,
    Description                nvarchar(255) collate database_default,
    Status                    tinyint,
    allow_pull                bit,
    allow_sync_tran            bit,
    allow_anonymous            bit,
    allow_queued_tran        bit,
    enabled_for_internet    bit,
    third_party                bit
)

if (select category & @tranpublish_bit from master.dbo.sysdatabases where name = @database collate database_default) <> 0
    begin
        select @procname = quotename(@database) + '.sys.sp_MSretrieve_publication '
        insert into #publication_property exec @retcode = @procname @name
    end

if (select category & @mergepublish_bit from master.dbo.sysdatabases where name = @database collate database_default) <> 0
    begin
        select @procname = quotename(@database) + '.sys.sp_MSretrieve_mergepublication '
        insert into #publication_property exec @retcode = @procname @name
    end
select * from #publication_property
drop table #publication_property
GO
GRANT EXECUTE ON [sys].[sp_MSretrieve_publication_attributes] TO [public] AS [dbo]
GO
