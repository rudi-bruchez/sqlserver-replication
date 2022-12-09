SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddmergetriggers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddmergetriggers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddmergetriggers]
	@source_table [nvarchar](517),
	@table_owner [sysname],
	@column_tracking [int],
	@recreate_repl_views [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @trigger_type       tinyint
    declare @cmd                nvarchar(4000)
    declare @dbname             sysname
    declare @trigname           sysname
    declare @instrigname        sysname
    declare @updtrigname        sysname
    declare @deltrigname        sysname
    declare @tablenick          int    
    declare @replnick           binary(6)
    declare @artid              uniqueidentifier
    declare @guidstr            nvarchar(32)
    declare @owner              sysname
    declare @site               sysname
    declare @db                 sysname
    declare @object             sysname
    declare @tablenickchar      nvarchar(11)
    declare @retcode            int
    declare @objid              int
    declare @bitmap             varbinary(40)
    declare @viewname           sysname
    declare @tsview             sysname
    declare @current_mappings_viewname nvarchar(130)
    declare @past_mappings_viewname nvarchar(130)
    declare @owner_is_admin     bit
    declare @UnqualName         sysname  --rightmost name node
    declare @QualName1          sysname  
    declare @create_upto_triggertype tinyint
    declare @source_table_passed_in nvarchar(517)
    declare @maintainsmetadata    bit
    declare @instrigid            int
    declare @updtrigid            int
    declare @deltrigid            int
    declare @pubid                uniqueidentifier
    declare @prev_pubid           uniqueidentifier
    declare @before_name nvarchar(130)
    declare @beforeview sysname
    declare @islightweight bit
    declare @genhistory_viewname sysname
    declare @article_published		bit
    declare @subscriber_of_wellpartitionedarticle bit
    declare @using_logical_records	bit
    declare @has_missing_or_exluded_cols bit
    declare @use_subscriber_simple_trigger_template bit
    declare @identity_support		bit
    declare @max_colv_size_in_bytes	int
    declare @max_colv_size_in_bytes_str nvarchar(10)
    declare @rgcol sysname
    declare @delete_tracking bit
    declare @str_objid nvarchar(15)
    declare @create_generic_subscriber_trigger bit
    declare @sync_type int
    
        /* Security check */
    EXEC @retcode = dbo.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
        
    select @source_table_passed_in = @source_table -- the code below mucks around with @source_table. I need to save off the passed-in value since I pass that to sp_MSaddmergetriggers_internal.

    select @dbname = db_name()

    if @table_owner is not NULL
        select @source_table=QUOTENAME(@table_owner) + '.' + QUOTENAME(@source_table)

    set @objid =  OBJECT_ID(@source_table)
    set @str_objid = convert(nvarchar, @objid)
    
    select @rgcol = name from sys.columns where object_id = @objid and is_rowguidcol = 1

    -- Check whether the table is a heavy- or lightweight article.
    select top 1 @islightweight=lightweight, @artid=artid from dbo.sysmergearticles where objid=@objid

	if 0 = @islightweight
	begin
		if exists (select * from dbo.sysmergearticles where artid = @artid and sys.fn_MSmerge_islocalpubid(pubid) = 1)
			select @article_published = 1
		else
			select @article_published = 0
			
		if exists (select * from dbo.sysmergepartitioninfo where artid = @artid and logical_record_view is not null)
			select @using_logical_records = 1
		else
			select @using_logical_records = 0
	    
		set @subscriber_of_wellpartitionedarticle = 0
	    
		exec @retcode = sys.sp_MSissubscriber_of_wellpartitionedarticle @artid, @subscriber_of_wellpartitionedarticle output
		if @@error <> 0 or @retcode <> 0
			return 1
	        
		if exists (select * from sys.columns where object_id = @objid and (is_computed = 1 or system_type_id = type_id('timestamp')))
			or exists (select * from dbo.sysmergearticles where artid = @artid and (missing_cols <> 0 or excluded_cols <> 0))
			select @has_missing_or_exluded_cols = 1
		else
			select @has_missing_or_exluded_cols = 0

		if exists (select * from dbo.sysmergepartitioninfoview where artid = @artid and identity_support=1)
			select @identity_support = 1
		else
			select @identity_support = 0
			
		if exists (select * from dbo.sysmergepartitioninfoview where artid = @artid and delete_tracking=1)
			select @delete_tracking = 1
		else
			select @delete_tracking = 0

	      --we should not use the template to build the triggers when @partition_options of the article is 1
      	      -- yiche,  bug 405196
            declare @partition_options tinyint           
            select top 1 @partition_options = partition_options
            from dbo.sysmergepartitioninfoview
            where artid = @artid
			
		if @article_published = 0 and @using_logical_records = 0 and @subscriber_of_wellpartitionedarticle = 0  and @partition_options <>1
			select @use_subscriber_simple_trigger_template = 1
		else
			select @use_subscriber_simple_trigger_template = 0
			
		if exists (select * from dbo.sysmergearticles where artid = @artid and column_tracking = 1)
		begin
			declare @current_col_count int, @missing_col_count int
			select @current_col_count = count(*) 
				from sys.columns where object_id = @objid
			select @missing_col_count = coalesce((select max(missing_col_count) 
				from dbo.sysmergearticles where objid = @objid), 0)
			-- 12 bytes per column in table + 1 trailing byte for colv.
			select @max_colv_size_in_bytes = 12 * (@current_col_count + @missing_col_count) + 1
			if @max_colv_size_in_bytes > 2953
				select @max_colv_size_in_bytes = 2953
		end
		else
			select @max_colv_size_in_bytes = 1
	        
		select @max_colv_size_in_bytes_str = convert(nvarchar(10), @max_colv_size_in_bytes)
	end
	
    begin tran
    save tran sp_MSaddmergetriggers
    
    if 0=@islightweight
    begin
        -- set up the before image table if one is desired
        --exec sys.sp_MScreatebeforetable @objid
        select @UnqualName = PARSENAME(@source_table, 1)
        select @QualName1 = PARSENAME(@source_table, 2)
        if @UnqualName IS NULL
             goto FAILURE

        if @QualName1 is NULL
             select @QualName1 = SCHEMA_NAME(schema_id) from sys.objects where object_id = object_id(@UnqualName)

        -- fixup for variable length differences.  remove when vars expanded
        -- to new SQL SERVER 7.0 lengths

        select @owner = @QualName1
        select @object = @UnqualName

        --this is to find out if table owner is the dbo. Only then can the object be
        -- marked as system object.
        if @owner = 'dbo'
            select @owner_is_admin = 1
        else 
            select @owner_is_admin = 0
                    
        execute @retcode=sys.sp_MStablenickname @owner, @object, @tablenick output
        if @retcode<>0 or @@ERROR<>0 goto FAILURE
            
        -- Find out whether this article is updateable at that node. 
        set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)

        /* If column tracking wasn't passed in, just figure it out */
        if @column_tracking is null
            select @column_tracking = column_tracking from dbo.sysmergearticles 
            where artid = @artid
            
        select @tablenickchar = convert(nvarchar, @tablenick)
        exec @retcode=sys.sp_MSguidtostr @artid, @guidstr out
        if @retcode<>0 or @@ERROR<>0 
            goto FAILURE

        /* Drop the article's replication triggers if they preexist */
        exec sys.sp_MSdroparticletriggers @object, @owner
        if @@ERROR <> 0 or @retcode<>0
            goto FAILURE
        
        -- owner name removed
        set @viewname = 'MSmerge_ctsv_' + @guidstr
        set @tsview = 'MSmerge_tsvw_' + @guidstr
        set @current_mappings_viewname = 'MSmerge_cpmv_' + @guidstr
        set @past_mappings_viewname = 'MSmerge_ppmv_' + @guidstr
        
        set @instrigname = 'MSmerge_ins_' + @guidstr
        set @updtrigname = 'MSmerge_upd_' + @guidstr
        set @deltrigname = 'MSmerge_del_' + @guidstr

        set @genhistory_viewname = 'MSmerge_genvw_' + @guidstr
        
        if object_id(@viewname, 'V') is not NULL
        begin
            set @cmd = 'drop view dbo.' + @viewname
            execute (@cmd)
        end

        if object_id(@tsview, 'V') is not NULL
        begin
            set @cmd = 'drop view dbo.' + @tsview
            execute (@cmd)
        end

        if object_id(@current_mappings_viewname, 'V') is not NULL
        begin
            set @cmd = 'drop view dbo.' + @current_mappings_viewname
            execute (@cmd)
        end

        if object_id(@past_mappings_viewname, 'V') is not NULL
        begin
            set @cmd = 'drop view dbo.' + @past_mappings_viewname
            execute (@cmd)
        end

        if object_id(@genhistory_viewname, 'V') is not NULL
        begin
            set @cmd = 'drop view dbo.' + @genhistory_viewname
            execute (@cmd)
        end

        if 1 = @maintainsmetadata
        begin
            if @recreate_repl_views = 1
            begin
                -- regenerate repl_view_ that uses triggers for this article @artid
                -- they are expected inside trigger generation code
                select top 1 @pubid = pubid from dbo.sysmergearticles 
                where artid = @artid 
                order by pubid
                
                while @pubid is not null
                begin
                    exec @retcode = sys.sp_MScreate_article_repl_view @pubid, @artid
                    if @@error <> 0 or @retcode <> 0 goto FAILURE

                    select @prev_pubid = @pubid
                    select @pubid = NULL
                    
                    select top 1 @pubid = pubid from dbo.sysmergearticles 
                    where artid = @artid 
                    and pubid > @prev_pubid 
                    order by pubid
                end
            end

            -- create the before view so that it is consistent with the before image table
            -- create the real security before view only after the trigger creation
            -- check if there is a before image table. If so create a view from which public can select
            select @before_name = OBJECT_NAME(before_image_objid) from dbo.sysmergearticles where objid = @objid
            set @beforeview = 'MSmerge_bivw_' + @guidstr
            if (@before_name is not null)
            begin
                /* Create the a view on the before image table if it doesn't already exist. */
                /* this view is needed for security purposes since we don't want to grant rights 
                   on the before image table to all users */
                if object_id(@beforeview, 'V') is not NULL
                begin
                    exec (' drop view dbo.' + @beforeview)
                    if @@ERROR<>0 goto FAILURE                    
                end
                if object_id(@beforeview, 'V') is NULL
                begin
                    set @cmd = 'create view dbo.' + @beforeview + ' as
                        select * from dbo.' + @before_name 
                    execute (@cmd)
                    if @@ERROR<>0 goto FAILURE
                    execute sp_MS_marksystemobject @beforeview 
                    if @@ERROR<>0 goto FAILURE    
                end
            end
            
            exec @retcode= sys.sp_MSgetreplnick @replnick = @replnick out
			if @retcode<>0 or @@error<>0 
				return 1
            
           -- regenerate triggers
            select @trigger_type = 0 -- insert trigger (0=insert, 1=update, 2=delete)

            select @create_upto_triggertype = 2

			-- for nosync subscribers do not use the templated update trigger because we may have deleted columns that need to be considered.
			if exists (select * FROM dbo.sysmergesubscriptions
	        WHERE UPPER(subscriber_server) collate database_default = UPPER(@@servername) collate database_default 
            and db_name = @dbname and sync_type = 2 and pubid in (select pubid from sysmergearticles where artid = @artid))
            begin
            	select @sync_type = 2
            end
            else
            begin
            	select @sync_type = 0
            end

            while (@trigger_type <= @create_upto_triggertype)
            begin
                select @trigname = case 
                                        when @trigger_type = 0 then @instrigname 
                                        when @trigger_type = 1 then @updtrigname  
                                        when @trigger_type = 2 then @deltrigname 
                                   end
                                   
                if @use_subscriber_simple_trigger_template = 1 and (@trigger_type <> 1 or (@has_missing_or_exluded_cols = 0 and @sync_type <> 2) or @column_tracking = 0)
								and (@trigger_type <> 0 or @identity_support = 0) and (@trigger_type <> 2 or @delete_tracking = 1)
                begin
					select @cmd = 'exec sys.sp_MSaddmergetriggers_from_template ''' + @tablenickchar + 
								''', N''' + sys.fn_replreplacesinglequote(@source_table_passed_in) collate database_default + 
                                ''', ' + sys.fn_replreplacesinglequoteplusprotectstring(@table_owner) collate database_default + 
                                ', ' + sys.fn_replreplacesinglequoteplusprotectstring(@rgcol) collate database_default + 
                                ', ' + isnull(convert(nvarchar, @column_tracking), 'NULL') + ', ' + convert(nvarchar, @trigger_type) + 
                                ', ''' + sys.fn_replreplacesinglequote(@viewname) collate database_default + '''' + 
                                ', ''' + sys.fn_replreplacesinglequote(@tsview) collate database_default + '''' + 
                                ', ''' + sys.fn_replreplacesinglequote(@trigname) collate database_default + ''''+ 
                                ', ''' + sys.fn_replreplacesinglequote(@genhistory_viewname) collate database_default + '''' +
                                ', ' + sys.fn_varbintohexstr(@replnick) +
                                ', ''' + @max_colv_size_in_bytes_str + ''''
                                
					exec (@cmd)
					if @@ERROR<>0 goto FAILURE
                end
                else
                begin
                
					select @cmd = 'exec sys.sp_MSaddmergetriggers_internal N''' + sys.fn_replreplacesinglequote(@UnqualName) collate database_default + 
                                ''', ' + sys.fn_replreplacesinglequoteplusprotectstring(@QualName1) collate database_default + ', ' + 
                                isnull(convert(nvarchar, @column_tracking), 'NULL') + ', ' + convert(nvarchar, @trigger_type) + 
                                ', ''' + sys.fn_replreplacesinglequote(@viewname) collate database_default + '''' + 
                                ', ''' + sys.fn_replreplacesinglequote(@tsview) collate database_default + '''' + 
                                ', ''' + sys.fn_replreplacesinglequote(@trigname) collate database_default + ''''+ 
                                ', ''' + sys.fn_replreplacesinglequote(@current_mappings_viewname) collate database_default + ''''+ 
                                ', ''' + sys.fn_replreplacesinglequote(@past_mappings_viewname) collate database_default + '''' +
                                ', ''' + sys.fn_replreplacesinglequote(@genhistory_viewname) collate database_default + '''' 

					if @using_logical_records = 1 or 
					(select sum(datalength(smsf.filtername) + 2 * datalength(smsf.join_filterclause) 
							+ 2 * datalength(smsf.join_articlename) + 2 * datalength(sma.name) + 100) 
							from sysmergesubsetfilters smsf join sysmergearticles sma 
							on smsf.art_nickname = sma.nickname
							where smsf.art_nickname = @tablenick) > 1000

--					(select count(*) from dbo.sysmergesubsetfilters where art_nickname = @tablenick
--                        or join_nickname = @tablenick) >= 10 -- arbitrary limit.
						-- if there is a logical record then the update trigger has rows larger than nvarchar(4000)
                        -- if there are too many join filters on an article, the number of characters
                        -- in the sync view definition could be more than nvarchar(4000) which
                        -- xp_execresultset does not handle well. Use sp_execresultset_nvarcharmax instead,
                        -- but not always because it does not perform well because of nvarchar(max) perf.
					begin
						exec @retcode = sys.sp_execresultset_nvarcharmaxrows @cmd
						if @@ERROR<>0 OR @retcode<>0 goto FAILURE
					end
					else
					begin
					    exec @retcode = sys.xp_execresultset @cmd, @dbname
				        if @@ERROR<>0 OR @retcode<>0 goto FAILURE
                    end
                end
           
                if (@owner_is_admin = 1)
                begin
                    declare @temp_qual_trigname nvarchar(300)
                    select @temp_qual_trigname = quotename(@owner) + '.' + quotename(@trigname)
                    exec sp_MS_marksystemobject @temp_qual_trigname
                    if @@error<>0 goto FAILURE
                end
                
                select @trigger_type = @trigger_type + 1
            end


            -- generate view here that uses the triggers
            select @instrigid = object_id(quotename(@owner) + '.' + quotename(@instrigname))
            select @updtrigid = object_id(quotename(@owner) + '.' + quotename(@updtrigname))
            select @deltrigid = object_id(quotename(@owner) + '.' + quotename(@deltrigname))
            
            -- check if there is a before image table. If so create a view from which public can select
            select @before_name = OBJECT_NAME(before_image_objid) from sysmergearticles where objid = @objid
            set @beforeview = 'MSmerge_bivw_' + @guidstr
            if (@before_name is not null)
            begin
                /* Create the a view on the before image table if it doesn't already exist. */
                /* this view is needed for security purposes since we don't want to grant rights 
                   on the before image table to all users */
                if object_id(@beforeview, 'V') is not NULL
                begin
                    exec (' drop view dbo.' + @beforeview)
                    if @@ERROR<>0 goto FAILURE                    
                end
                if object_id(@beforeview, 'V') is NULL
                begin
                    set @cmd = 'create view dbo.' + @beforeview + ' as
                        select * from dbo.' + @before_name + ' where
                            trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                            trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                            trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                            with check option'
                    execute (@cmd)
                    if @@ERROR<>0 goto FAILURE
                    set @cmd = 'grant update, insert, select, delete on ' + @beforeview + ' to public'
                    execute (@cmd)
                    if @@ERROR<>0 goto FAILURE
                    execute sp_MS_marksystemobject @beforeview   
                    if @@ERROR<>0 goto FAILURE    
                end
            end
            
            set @cmd = '
                create view dbo.' + @viewname + ' as
                select * from dbo.MSmerge_contents where
                trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                with check option'
                
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE
            set @cmd = 'grant update, insert, select, delete on ' + @viewname + ' to public'
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE
            execute sp_MS_marksystemobject @viewname
            if @@ERROR<>0 goto FAILURE

            set @cmd = '
                create view dbo. ' + @tsview + ' as
                select * from dbo.MSmerge_tombstone where
                trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                with check option'
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE
            set @cmd = 'grant update, insert, select, delete on ' + @tsview + ' to public'
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE        
            execute sp_MS_marksystemobject @tsview 
            if @@ERROR<>0 goto FAILURE

            if (exists (select * from sysmergearticles where artid = @artid and pubid in (select pubid from sysmergepublications where use_partition_groups = 1)))
            begin
                set @cmd = '
                    create view dbo.' + @current_mappings_viewname + ' as
                    select * from dbo.MSmerge_current_partition_mappings where
                    trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                    trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                    trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                    with check option'
                execute (@cmd)
                if @@ERROR<>0 goto FAILURE
                set @cmd = 'grant update, insert, select, delete on ' + @current_mappings_viewname + ' to public'
                execute (@cmd)
                if @@ERROR<>0 goto FAILURE
                execute sp_MS_marksystemobject @current_mappings_viewname 
                if @@ERROR<>0 goto FAILURE
                
                set @cmd = '
                    create view dbo.' + @past_mappings_viewname + ' as
                    select * from dbo.MSmerge_past_partition_mappings where
                    trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                    trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                    trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                    with check option'
                execute (@cmd)
                if @@ERROR<>0 goto FAILURE
                set @cmd = 'grant update, insert, select, delete on ' + @past_mappings_viewname + ' to public'
                execute (@cmd)
                if @@ERROR<>0 goto FAILURE
                execute sp_MS_marksystemobject @past_mappings_viewname 
                if @@ERROR<>0 goto FAILURE        
            end
            
            set @cmd = '
                create view dbo.' + @genhistory_viewname + ' as
                select * from dbo.MSmerge_genhistory where
                trigger_nestlevel(' + convert(nvarchar,@instrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@updtrigid) + ') > 0 or
                trigger_nestlevel(' + convert(nvarchar,@deltrigid) + ') > 0
                with check option'
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE
            set @cmd = 'grant update, insert, select, delete on ' + @genhistory_viewname + ' to public'
            execute (@cmd)
            if @@ERROR<>0 goto FAILURE
            execute sp_MS_marksystemobject @genhistory_viewname  
            if @@ERROR<>0 goto FAILURE

            if @recreate_repl_views = 1
            begin
                -- regenerate repl_view_ that uses triggers for this article @artid
                select top 1 @pubid = pubid from dbo.sysmergearticles 
                where artid = @artid 
                order by pubid

                while @pubid is not null
                begin
                    exec @retcode = sys.sp_MScreate_article_repl_view @pubid, @artid
                    if @@error <> 0 or @retcode <> 0 goto FAILURE

                    select @prev_pubid = @pubid
                    select @pubid = NULL
                    
                    select top 1 @pubid = pubid from dbo.sysmergearticles 
                    where artid = @artid 
                    and pubid > @prev_pubid 
                    order by pubid
                end
            end
        end
        else
        begin
            -- Create trigger that disallows local updates/inserts/deletes.
            exec @retcode= sys.sp_MScreatedownloadonlytriggers @artid= @artid
            if @@error <> 0 or @retcode <> 0 goto FAILURE
        end
    end -- 0=@islightweight
    else
    begin
        exec @retcode= sys.sp_MSdroplightweighttriggers @artid=@artid
        if @@error <> 0 or @retcode <> 0 goto FAILURE

        -- Find out whether this article is updateable at that node. 
        set @maintainsmetadata= sys.fn_MSarticle_allows_DML_at_this_replica(@artid, default)

        if 1=@maintainsmetadata
        begin
            exec @retcode= sys.sp_MScreatelightweighttriggers @artid= @artid
            if @@error <> 0 or @retcode <> 0 goto FAILURE
        end
        else
        begin
            -- Create trigger that disallows local updates/inserts/deletes.
            exec @retcode= sys.sp_MScreatedownloadonlytriggers @artid= @artid
            if @@error <> 0 or @retcode <> 0 goto FAILURE
        end
    end

    exec @retcode = sys.sp_MSdropdisabledmltrigger @source_table_passed_in, @table_owner
    if @@error <> 0 or @retcode <> 0 
        goto FAILURE

    commit tran

    return 0

FAILURE:
    rollback tran sp_MSaddmergetriggers
    commit tran
    raiserror(20715, 10, -1, @source_table)
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSaddmergetriggers] TO [public] AS [dbo]
GO
