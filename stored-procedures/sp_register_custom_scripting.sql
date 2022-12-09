SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_register_custom_scripting]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_register_custom_scripting] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_register_custom_scripting]
	@type [varchar](16),
	@value [nvarchar](2048),
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
begin
	if (sys.fn_MSrepl_istranpublished (db_name(),0) != 1)
	begin
		raiserror(18757, 16, -1)
		return (1)
	end
	--
	-- security check
	--
	declare @retcode int
	exec @retcode = sys.sp_MSreplcheck_publish_withddladmin
	if @@error <> 0 or @retcode <> 0
	begin
	    return (1)
	end

	declare @procText nvarchar(max)
			,@register_type tinyint
			,@register_ins tinyint
			,@register_del tinyint
			,@register_upd tinyint
			,@register_custom_script tinyint
			,@auto_genproc tinyint
			,@pubname sysname
			,@artname sysname

	select @register_ins = 1
		,@register_del  = 2
		,@register_upd = 3
		,@register_custom_script = 4
		,@auto_genproc = 0x02


    	select  @register_type = case 
    		when patindex( upper(@type collate SQL_Latin1_General_CP1_CS_AS) + '%', 'INSERT' ) = 1 then @register_ins
    		when patindex( upper(@type collate SQL_Latin1_General_CP1_CS_AS) + '%', 'DELETE' ) = 1 then @register_del
    		when patindex( upper(@type collate SQL_Latin1_General_CP1_CS_AS) + '%', 'UPDATE' ) = 1 then @register_upd
    		when patindex( upper(@type collate SQL_Latin1_General_CP1_CS_AS) + '%', 'CUSTOM_SCRIPT' ) = 1 then @register_custom_script
    		else 0 end

	if @register_type not in (@register_ins, @register_del, @register_upd, @register_custom_script)
	begin
	    raiserror(21402, 16, 11, '@type')
	    return (1)
	end
	
	if (@register_type in (@register_ins, @register_del, @register_upd)) and ((@value is not null) and (object_id(@value) is null))
	begin
	    raiserror(21402, 16, 11, '@value')
	    return (1)
	end

	
	if @publication is not NULL and len (@publication) >= 1
	begin
		--not all publications, check for valid publication name
		EXECUTE @retcode = sys.sp_validname @publication

		if @retcode <> 0
			return (1)

		if not exists (select * from syspublications where name = @publication)
		begin
			raiserror(20026, 16, -1, @publication)	
			return (1)
		end
		select @pubname = @publication
	end
	else
	begin
		--all publications
		select @pubname = '%'
	end

	if @article is not NULL and len (@article) >= 1
	begin
		--not all articles, check for valid publication name
		EXECUTE @retcode = sys.sp_validname @article

		if @retcode <> 0
			return (1)

		if not exists (select * from sysarticles where name = @article)
		begin
			raiserror(20027, 16, -1, @article)	
			return (1)
		end
		select @artname = @article
	end
	else
	begin
		--all articles
		select @artname = '%'
	end

	--let's not check for 'SQL' format here, if @auto_genproc is on and one of ins/del/upd is using 'SQL'
	--sp_addarticle/sp_changearticle should be the right place to handle it, not here
		
	-- the difference between ins/del/upd proc and custom_script, is the former applies to article with schema_option & 0x02 = 0x02
	-- while the later applied to the opposite, -- articles with schema_options & 0x02 <> 0x02
			
	-- NULL @value means unregister
		
	select @procText = N'update dbo.sysarticles set ' + case @register_type when @register_ins then N'ins_scripting_proc = '
																		when @register_del then N'del_scripting_proc = '
																		when @register_upd then N'upd_scripting_proc = '
																		when @register_custom_script then N'custom_script = '
																		end
						+ case @register_type when @register_custom_script then isnull(N'''' + sys.fn_replreplacesinglequote(@value) + N'''', 'NULL')
																else isnull(cast(object_id(@value) as varchar(12)), 'NULL')
																end
						+ N' from sysarticles sa join syspublications sp on sa.pubid = sp.pubid
					where cast(sa.schema_option as int) & ' + cast (@auto_genproc as varchar(12) )
						+ case @register_type when @register_ins then N' = '
										when @register_del then N' = '
										when @register_upd then N' = '
										when @register_custom_script then N' <> '
										end
						+ cast (@auto_genproc as varchar(12) ) 
						+ N' and sp.name like ''' + @pubname + N'''
							and sa.name like ''' + @artname + N''''
		
		exec (@procText)

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_register_custom_scripting] TO [public] AS [dbo]
GO
