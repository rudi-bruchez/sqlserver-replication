SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScleanupdynsnapshotvws]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScleanupdynsnapshotvws] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScleanupdynsnapshotvws]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on    
	declare @retcode int
	select @retcode = 0
	
	-- Security check
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error<>0 or @retcode<>0
	begin
		return 1
	end

	-- Do nothing if the MSdynamicsnapshotviews table does not exist
	if exists (select * from sys.objects where name = N'MSdynamicsnapshotviews')
	begin
		declare @dynamic_snapshot_view_name sysname
		declare @drop_view_command nvarchar(4000) 

		declare hViews cursor local fast_forward for
		 select dynamic_snapshot_view_name
		   from MSdynamicsnapshotviews
		if @@error<>0
		begin
			goto Failure
		end
		
		open hViews
		if @@error<>0
		begin
		   goto Failure
		end
	
		fetch hViews into @dynamic_snapshot_view_name
		while (@@fetch_status<>-1)
		begin
			select @drop_view_command = 'drop view ' + 
				quotename(@dynamic_snapshot_view_name)
			exec(@drop_view_command)
			if @@error<>0
			begin
				select @retcode = 1 -- Just to indicate that a failure occurred
			end        
			delete from MSdynamicsnapshotviews
			 where dynamic_snapshot_view_name = @dynamic_snapshot_view_name
			if @@error<>0
			begin
				select @retcode = 1 -- Just to indicate that a failure occurred
			end        
			fetch hViews into @dynamic_snapshot_view_name
		end
	end
	return @retcode
Failure:
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MScleanupdynsnapshotvws] TO [public] AS [dbo]
GO
