SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_partitionid_eval_proc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_partitionid_eval_proc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_partitionid_eval_proc]
	@partition_id_eval_proc [sysname],
	@pubid [uniqueidentifier],
	@publication_number [smallint],
	@column_list [nvarchar](2000),
	@function_list [nvarchar](2000),
	@partition_id_eval_clause [nvarchar](2000),
	@use_partition_groups [smallint]
WITH EXECUTE AS CALLER
AS
begin
    declare @cmdtemp nvarchar(max),
            @retcode int

    -- Security check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

    create table #tmpevalproccmd (phase int NOT NULL, cmdtext nvarchar(max) collate database_default null)

    select @cmdtemp = N'create procedure dbo.' + sys.fn_replreplacesinglequote(quotename(@partition_id_eval_proc)) collate database_default + N' @partition_id int OUTPUT, @maxgen_whenadded bigint OUTPUT, @host_name_override sysname = NULL, @suser_sname_override sysname = NULL as
    begin
        declare @retcode int
        declare @function_values_overridden bit
        declare @overridden_function_list nvarchar(2000)
        declare @temp_overridden_function_list nvarchar(2001)
        declare @overridden_eval_clause nvarchar(2000)
        declare @command nvarchar(max)
        declare @dbname sysname
        declare @using_partition_groups bit
        declare @is_partition_active bit
        declare @app_lock_resource nvarchar(255)

        if ({ fn ISPALUSER(N''' + convert(nvarchar(36),@pubid) + ''') } <> 1)
        begin
            RAISERROR (14126, 11, -1)
            return (1)
        end

        select @dbname = quotename(db_name())
        select @host_name_override = replace(@host_name_override, '''''''', '''''''''''')
        select @suser_sname_override = replace(@suser_sname_override, '''''''', '''''''''''')
'
    
    insert into #tmpevalproccmd (phase, cmdtext) values(1, @cmdtemp)
    
    if @partition_id_eval_clause is null
        select @cmdtemp = N'
        select @partition_id = -1'
    else
    begin
        select @cmdtemp = N' 
        select @partition_id = NULL
        select @function_values_overridden = 0

        select @overridden_function_list = N''' + sys.fn_replreplacesinglequote(@function_list) + N'''
        select @overridden_eval_clause = N''' + sys.fn_replreplacesinglequote(@partition_id_eval_clause) + N'''

        if @host_name_override is not null and @host_name_override != ''''
        begin
            select @temp_overridden_function_list = N'','' + @overridden_function_list
            select @temp_overridden_function_list = replace(@temp_overridden_function_list collate SQL_Latin1_General_CP1_CI_AS, '',host_name()'' collate SQL_Latin1_General_CP1_CI_AS, '','''''' + @host_name_override + '''''''')
            select @overridden_function_list = substring(@temp_overridden_function_list, 2, len(@temp_overridden_function_list)-1)
            select @overridden_eval_clause = replace(@overridden_eval_clause collate SQL_Latin1_General_CP1_CI_AS, ''= host_name()'' collate SQL_Latin1_General_CP1_CI_AS, ''= '''''' + @host_name_override + '''''''')
            select @function_values_overridden = 1
        end

        if @suser_sname_override is not null and @suser_sname_override != ''''
        begin
            select @temp_overridden_function_list = N'','' + @overridden_function_list
            select @temp_overridden_function_list = replace(@temp_overridden_function_list collate SQL_Latin1_General_CP1_CI_AS, '',suser_sname()'' collate SQL_Latin1_General_CP1_CI_AS, '','''''' + @suser_sname_override + '''''''')
            select @overridden_function_list = substring(@temp_overridden_function_list, 2, len(@temp_overridden_function_list)-1)
            select @overridden_eval_clause = replace(@overridden_eval_clause collate SQL_Latin1_General_CP1_CI_AS, ''= suser_sname()'' collate SQL_Latin1_General_CP1_CI_AS, ''= '''''' + @suser_sname_override + '''''''')
            select @function_values_overridden = 1
        end

        if @function_values_overridden = 0
            select @partition_id = partition_id, @maxgen_whenadded = maxgen_whenadded, @using_partition_groups = using_partition_groups, @is_partition_active = is_partition_active 
            from dbo.MSmerge_partition_groups 
            where ' + sys.fn_replreplacesinglequote(@partition_id_eval_clause) + N'
            and publication_number = ' + convert(nvarchar, @publication_number) + N'
        else
        begin
            select @command = N''select @partition_id = partition_id, @maxgen_whenadded = maxgen_whenadded, @using_partition_groups = using_partition_groups, @is_partition_active = is_partition_active 
            from '' + @dbname + N''.[dbo].[MSmerge_partition_groups] 
            where '' + @overridden_eval_clause + N''
            and publication_number = ' + convert(nvarchar, @publication_number) + N'''

            exec sys.sp_executesql @command, N''@partition_id int output, @maxgen_whenadded int output, @using_partition_groups bit output, @is_partition_active bit output'', @partition_id=@partition_id output, @maxgen_whenadded=@maxgen_whenadded output, @using_partition_groups = @using_partition_groups output, @is_partition_active = @is_partition_active output
        end
        
        if @partition_id is null '
        
        insert into #tmpevalproccmd (phase, cmdtext) values(2, @cmdtemp)
        
        if @use_partition_groups > 0 
            select @cmdtemp = N' or @is_partition_active = 0 or @using_partition_groups = 0 '
        else
            select @cmdtemp = N' '
        
        select @cmdtemp = @cmdtemp + N'
        begin
            begin tran

            select @maxgen_whenadded = max(generation) from dbo.MSmerge_genhistory with (updlock) '

        if @use_partition_groups > 0 
        begin
            select @cmdtemp = @cmdtemp + N'
            if @partition_id is null
            begin
                if @function_values_overridden = 0
                    insert into dbo.MSmerge_partition_groups( ' + sys.fn_replreplacesinglequote(@column_list) + N', publication_number, maxgen_whenadded, using_partition_groups, is_partition_active) values (' + sys.fn_replreplacesinglequote(@function_list) + N', ' + convert(nvarchar, @publication_number) + N', @maxgen_whenadded, 1, 0)
                else
                begin
                    select @command = N''insert into dbo.MSmerge_partition_groups( ' + sys.fn_replreplacesinglequote(@column_list) + N', publication_number, maxgen_whenadded, using_partition_groups, is_partition_active) values ('' + @overridden_function_list + '', ' + convert(nvarchar, @publication_number) + N', '' + convert(nvarchar, @maxgen_whenadded) + '', 1, 0)''
                    exec (@command)
                end
            end
            else
            begin
                update dbo.MSmerge_partition_groups set maxgen_whenadded = @maxgen_whenadded, using_partition_groups = 1, is_partition_active = 0
                where partition_id = @partition_id 
                and publication_number = ' + convert(nvarchar, @publication_number) + N'
            end '
        end  -- if @use_partition_groups > 0
        else
        begin
            select @cmdtemp = @cmdtemp + N'    
            if @function_values_overridden = 0
                insert into dbo.MSmerge_partition_groups( ' + sys.fn_replreplacesinglequote(@column_list) + N', publication_number, maxgen_whenadded, using_partition_groups, is_partition_active) values (' + sys.fn_replreplacesinglequote(@function_list) + N', ' + convert(nvarchar, @publication_number) + N', @maxgen_whenadded, 0, 1)
            else
            begin
                select @command = N''insert into dbo.MSmerge_partition_groups( ' + sys.fn_replreplacesinglequote(@column_list) + N', publication_number, maxgen_whenadded, using_partition_groups, is_partition_active) values ('' + @overridden_function_list + '', ' + convert(nvarchar, @publication_number) + N', '' + convert(nvarchar, @maxgen_whenadded) + '', 0, 1)''
                exec (@command)
            end '
        end -- else block
        
        select @cmdtemp = @cmdtemp + N'
            commit tran

            if @partition_id is null
                select @partition_id = @@identity '

        insert into #tmpevalproccmd (phase, cmdtext) values(3, @cmdtemp)
        select @cmdtemp = ''

        if @use_partition_groups > 0
        begin
            -- First we look for the entry for this clause that has the lowest partition_id and delete all that are greater than this lowest partition_id.
            -- This is to protect against multiple subscribers with the same filter clause inserting new rows in MSmerge_partition_groups simultaneously. 
            -- We then work with this lowest partition_id
            select @cmdtemp = @cmdtemp + N'
            if @function_values_overridden = 0
            begin
                select top 1 @partition_id = partition_id, @maxgen_whenadded = maxgen_whenadded, @using_partition_groups = using_partition_groups, @is_partition_active = is_partition_active 
                from dbo.MSmerge_partition_groups 
                where ' + sys.fn_replreplacesinglequote(@partition_id_eval_clause) + N'
                and publication_number = ' + convert(nvarchar, @publication_number) + N' order by partition_id asc
                
                delete from dbo.MSmerge_partition_groups where ' + sys.fn_replreplacesinglequote(@partition_id_eval_clause) + N'
                and partition_id > @partition_id and publication_number = ' + convert(nvarchar, @publication_number) + N'
            end
            else
            begin
                select @command = N''select top 1 @partition_id = partition_id, @maxgen_whenadded = maxgen_whenadded, @using_partition_groups = using_partition_groups, @is_partition_active = is_partition_active 
                from '' + @dbname + N''.[dbo].[MSmerge_partition_groups] 
                where '' + @overridden_eval_clause + N''
                and publication_number = ' + convert(nvarchar, @publication_number) + N' order by partition_id asc''

                exec sys.sp_executesql @command, N''@partition_id int output, @maxgen_whenadded int output, @using_partition_groups bit output, @is_partition_active bit output'', @partition_id=@partition_id output, @maxgen_whenadded=@maxgen_whenadded output, @using_partition_groups = @using_partition_groups output, @is_partition_active = @is_partition_active output

                select @command = N''delete from '' + @dbname + N''.[dbo].[MSmerge_partition_groups] where '' + @overridden_eval_clause + N'' 
                and partition_id > @partition_id and publication_number = ' + convert(nvarchar, @publication_number) + N'''
                exec sys.sp_executesql @command, N''@partition_id int'', @partition_id = @partition_id 
            end'

            -- Now take an exlusive applock for this lowest partition_id and do all the eval setup work (making sure that partition is still not active)
            insert into #tmpevalproccmd (phase, cmdtext) values(4, @cmdtemp)
            select @cmdtemp = '
            select @app_lock_resource = N''MSmerge_evalpartid_' + convert(nvarchar, @publication_number) + N'_'' + convert(nvarchar, @partition_id)
            exec @retcode = sp_getapplock @Resource = @app_lock_resource,
                                  @LockMode = N''Exclusive'',
                                  @LockOwner = N''Session'',
                                  @LockTimeout = -1,
                                  @DbPrincipal = N''MSmerge_PAL_role''
            if @@error<>0 or @retcode<0
                return 1

            select @is_partition_active = is_partition_active from dbo.MSmerge_partition_groups where
            	    partition_id = @partition_id and publication_number = ' + convert(nvarchar, @publication_number) + N'

            if (@is_partition_active = 0)
            begin
                -- the following needs to be done only when using partition ids
                -- create a dummy generation if using partition groups. This is needed because with recent makegeneration changes
                -- we may have no open generation in genhistory. Now if we dont create a dummy generation that is higher than
                -- @maxgen_whenadded our watermark may end up being maxgen_whenadded. Then even for the next merge since maxgen_whenadded
                -- changes could potentially be enumerated we will use setupbelongs instead of partition groups.
                exec @retcode = sys.sp_MScreatedummygeneration @pubid = ''' + convert(nvarchar(36), @pubid) + ''', @maxgen_whenadded = @maxgen_whenadded
                if @retcode <> 0 or @@error <> 0
                begin
                    select @retcode = 1
                    goto error
                end'

            insert into #tmpevalproccmd (phase, cmdtext) values(5, @cmdtemp)
            select @cmdtemp = '
                -- only do that following if there are some rows in contents
                if exists (select * from dbo.MSmerge_contents)
                begin
                    exec @retcode = sys.sp_MSevaluate_change_membership_for_pubid @pubid = ''' + convert(nvarchar(36), @pubid) + ''', @partition_id = @partition_id
                    if @retcode <> 0 or @@error <> 0
                    begin
                        select @retcode = 1
                        goto error
                    end
                end

                exec @retcode = sys.sp_MSmap_partitionid_to_generations @partition_id = @partition_id
                if @retcode <> 0 or @@error <> 0
                begin
                    select @retcode = 1
                    goto error
                end

                update dbo.MSmerge_partition_groups set is_partition_active = 1 
                where partition_id = @partition_id and publication_number = ' + convert(nvarchar, @publication_number) + N'
            end
error:      
            exec sp_releaseapplock @Resource = @app_lock_resource, @LockOwner = N''Session'', @DbPrincipal = N''MSmerge_PAL_role''
            if (@retcode = 1) --If we got here because of an earlier error then bail
                return 1'
        end            
        select @cmdtemp = @cmdtemp + N'
        end '
    end
    
    select @cmdtemp = @cmdtemp + N'
        return 0
    end
    '
    insert into #tmpevalproccmd (phase, cmdtext) values(6, @cmdtemp)
    
    select cmdtext from #tmpevalproccmd order by phase
    
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_partitionid_eval_proc] TO [public] AS [dbo]
GO
