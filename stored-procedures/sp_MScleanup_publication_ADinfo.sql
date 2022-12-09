SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanup_publication_ADinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanup_publication_ADinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanup_publication_ADinfo]
	@name [sysname],
	@database [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

declare @mergepublish_bit    int
declare @tranpublish_bit    int
declare @cmd            nvarchar(640)

select @mergepublish_bit    = 4 
select @tranpublish_bit     = 1

/*
** Security Check
*/
select @cmd = quotename(@database) + '.sys.sp_MSreplcheck_publish'
exec @cmd
IF @@ERROR <> 0
    return (1)

if (select category & @tranpublish_bit from master.dbo.sysdatabases where name = @database collate database_default) <> 0
    begin
        select @cmd = N'update' + quotename(@database) + N'.dbo.syspublications set ad_guidname=NULL where name=N' + quotename(@name, N'''')
        exec (@cmd)
    end

if (select category & @mergepublish_bit from master.dbo.sysdatabases where name = @database collate database_default) <> 0
    begin
        select @cmd = N'update' + quotename(@database) + N'.dbo.sysmergepublications set ad_guidname=NULL where name=N' + quotename(@name, N'''')
        exec (@cmd)
    end
GO
GRANT EXECUTE ON [sys].[sp_MScleanup_publication_ADinfo] TO [public] AS [dbo]
GO
