SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replcleanupccsprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replcleanupccsprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replcleanupccsprocs]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
			,@pub_artid int
			,@del_format int
			,@ins_format int
			,@ins_cmd_is_null int
			,@del_cmd_is_null int
			,@pubid int

	/*
	** Security Check, this proc is called by snapshot agent as DBO on publisher
	*/
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@ERROR <> 0 or @retcode <> 0
	begin
			return(1)
	end
	/*
	** post drop for all applicable articles in the publication
	*/
	DECLARE #articles CURSOR LOCAL FAST_FORWARD FOR 
	select art.pubid, artid, 
			case 
				when charindex( N'CALL', upper(ins_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 1  
				when charindex( N'SCALL', upper(ins_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 5                        
				else 0 end,
			case 
				when charindex( N'CALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 1  
				when charindex( N'XCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 3  
				when charindex( N'VCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 4
				else 0 end,
			case 
				when ins_cmd is null then 1
				when charindex( N'CALL', upper(ins_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 0
				when charindex( N'SCALL', upper(ins_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 0
				else 1 end,
			case when del_cmd is null then 1
				when charindex( N'CALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 0  
				when charindex( N'XCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 0  
				when charindex( N'VCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 0
				else 1 end
	from sysarticles art join syspublications pub on art.pubid = pub.pubid where pub.name = @publication and art.type not in (8, 24)

	OPEN #articles
	FETCH #articles INTO @pubid, @pub_artid, @ins_format, @del_format, @ins_cmd_is_null, @del_cmd_is_null
	WHILE (@@fetch_status <> -1)
	BEGIN

		--
		--post the resultset of sp_scriptinsproccore for droponly
		--
		if @ins_cmd_is_null = 0
		begin
			exec @retcode = sys.sp_MSpost_auto_proc @pubid = @pubid, @artid = @pub_artid, @procmapid = 6, @format = @ins_format
			if(@retcode <> 0) or (@@error <> 0)
			begin
				return 1
			end
		end

		--
		--post the resultset of sp_scriptdelproccore for droponly
		--
		if @del_cmd_is_null = 0
		begin
			exec @retcode = sys.sp_MSpost_auto_proc @pubid = @pubid, @artid = @pub_artid, @procmapid = 7, @format = @del_format
			if(@retcode <> 0) or (@@error <> 0)
			begin
				return 1
			end
		end
		
		FETCH #articles INTO @pubid, @pub_artid, @ins_format, @del_format, @ins_cmd_is_null, @del_cmd_is_null
	END -- end of cursur loop
	CLOSE #articles
	DEALLOCATE #articles
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replcleanupccsprocs] TO [public] AS [dbo]
GO
