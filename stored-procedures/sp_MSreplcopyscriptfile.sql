SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplcopyscriptfile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplcopyscriptfile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplcopyscriptfile]
	@directory [nvarchar](4000),
	@scriptfile [nvarchar](4000)
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int
	
	--
	-- security check
	-- only sysadmin can execute this
	--
	if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
	begin try
		exec @retcode = xp_create_subdir @directory
	end try
	begin catch
		set @retcode = 1
	end catch
	if(@retcode <> 0)
	begin
		raiserror(21330, 16, -1, @directory)
		return (1)
	end

	begin try
		exec @retcode = xp_copy_files @scriptfile, @directory
	end try
	begin catch
		set @retcode = 1
	end catch
	if(@retcode <> 0)
	begin 
		raiserror(21331, 16, -1, @directory)
		return (1)
	end

	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSreplcopyscriptfile] TO [public] AS [dbo]
GO
