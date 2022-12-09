SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscriptcustomdelproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscriptcustomdelproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscriptcustomdelproc]
	@artid [int],
	@publishertype [tinyint],
	@publisher [sysname],
	@usesqlclr [bit],
	@inDDLrepl [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
			,@scripting_proc nvarchar(512)
			,@delformat int
	--
	-- security check
	--
	exec @retcode = sys.sp_MSreplcheck_publish_withddladmin
	if @@error <> 0 or @retcode <> 0
	begin
	    return (1)
	end

	select @scripting_proc = quotename(object_name(del_scripting_proc))
			,@delformat = case 
			    		when charindex( N'CALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 1  
			    		when charindex( N'XCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 3  
			    		when charindex( N'VCALL', upper(del_cmd collate SQL_Latin1_General_CP1_CS_AS) ) = 1 then 4
			    		else 0 end
		    from sysarticles where artid = @artid

	-- SQL/None upd_cmd does not involve scripting, return without doing anything here.
	if @delformat = 0 
		return 0

	if @scripting_proc is null
	begin
        if @usesqlclr = 1 and @publishertype = 1
        begin
            exec @retcode = sys.sp_MSscriptcustomdelproc_sqlclr
                @artid = @artid
                ,@publisher = @publisher
        end
        else
        begin
    		select @scripting_proc = case @delformat when 1 then N'sys.sp_scriptdelproc'
	    										when 3 then N'sys.sp_scriptxdelproc'
		    									when 4 then N'sys.sp_scriptvdelproc'
			    								else N'' end
		    exec @retcode = @scripting_proc @artid = @artid
			    						,@publishertype = @publishertype
				    					,@publisher = @publisher
        end
	end
	else
 	begin
		--
		-- For security: break ownership chain as
		-- we have no control over the proc name is
		--
		declare @spretcode int
				,@spcall nvarchar(512)
		declare @temptext table(colidx int identity, col nvarchar(max) collate database_default) 
		select @spcall = N'exec @p1 = ' + @scripting_proc + N' @artid = @p2 '
		if @inDDLrepl = 1
		begin
			exec @retcode = sys.sp_executesql @stmt = @spcall
				,@params = N'@p1 int output, @p2 int'
				,@p1 = @spretcode output
				,@p2 = @artid
		end 
		else
		begin
			insert @temptext(col) exec @retcode = sys.sp_executesql @stmt = @spcall
				,@params = N'@p1 int output, @p2 int'
				,@p1 = @spretcode output
				,@p2 = @artid
			select col from @temptext order by colidx
		end
		if (@retcode != 0 or @spretcode != 0)
			select @retcode = 1
	end

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSscriptcustomdelproc] TO [public] AS [dbo]
GO
