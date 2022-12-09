SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getsubscriptiondtspackagename]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getsubscriptiondtspackagename] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getsubscriptiondtspackagename]
	@publication [sysname],
	@subscriber [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @name sysname
    declare @name_full sysname
    declare @id    int
    declare @retcode int

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)
    
    select @id = 1
    select @name = @publication
    if @subscriber is not null
        select @name = @name + N'_' + @subscriber

    -- reserver space for numbers to make the name unique
    select @name = substring(@name, 1, 100)
    select @name_full = @name

    while (1=1)
    begin
        if not exists (select * from msdb.dbo.sysdtspackages where
            name = @name_full)
            break
        select @name_full = @name + '_' + convert(nvarchar(10), @id)
        select @id = @id + 1
    end
    select N'new_package_name' = @name_full
GO
GRANT EXECUTE ON [sys].[sp_getsubscriptiondtspackagename] TO [public] AS [dbo]
GO
