SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_filteringcolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_filteringcolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_filteringcolumn]
	@pubid [uniqueidentifier],
	@tablenick [int],
	@column_name [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int
	, @objid int
	, @column_id int

	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1
	
	select @objid = objid from dbo.sysmergearticles
	where pubid = @pubid
	and nickname = @tablenick
	
	if @objid is not null
	begin
		select @column_id = column_id from sys.columns
		where object_id = @objid
		and name = @column_name
		
		if @column_id is not null
		begin
			insert into dbo.MSmerge_filteringcolumns_lightweight (publication_id, tablenick, column_id) 
				select @pubid, @tablenick, @column_id
				where not exists (select * from dbo.MSmerge_filteringcolumns_lightweight
									where publication_id = @pubid
									and tablenick = @tablenick
									and column_id = @column_id)
		end
	end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_filteringcolumn] TO [public] AS [dbo]
GO
