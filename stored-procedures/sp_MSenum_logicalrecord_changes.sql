SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_logicalrecord_changes]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_logicalrecord_changes] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_logicalrecord_changes]
	@partition_id [int],
	@genlist [varchar](8000),
	@parent_nickname [int],
	@pubid [uniqueidentifier],
	@oldmaxgen [bigint],
	@mingen [bigint],
	@maxgen [bigint],
	@enumentirerowmetadata [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
create table #logical_record_changes (tablenick int NOT NULL, 
                                                rowguid uniqueidentifier NOT NULL, 
                                                generation bigint NULL, 
                                                lineage varbinary(311) NULL, 
                                                colv1 varbinary(2953) NULL, 
                                                logical_record_parent_rowguid uniqueidentifier NULL,
                                                iscontents bit default 1,
                                                ts_type tinyint NULL)
                                                
        create table #cont (tablenick int NOT NULL, 
                                                rowguid uniqueidentifier NOT NULL, 
                                                generation bigint NULL, 
                                                lineage varbinary(311) NULL, 
                                                colv1 varbinary(2953) NULL, 
                                                logical_record_parent_rowguid uniqueidentifier NULL,
                                                unique (tablenick, rowguid))

    declare @oldmaxgenstr                       nvarchar(25),
                        @retcode                                smallint,
                        @procname                               nvarchar(270),
                        @generation_clause1             nvarchar(max),
                        @generation_clause2             nvarchar(max),
                        @generation_clause3             nvarchar(max),
                        @maxgen_clause                  nvarchar(100),
                        @oldmaxgen_clause               nvarchar(100),
                        @cpm_generation_clause  nvarchar(100),
                        @cpm_maxgen_clause                      nvarchar(100),
                        @cpm_oldmaxgen_clause           nvarchar(100),
                        @mingenstr                              nvarchar(25),
                        @maxgenstr                              nvarchar(25),
                        @parent_nickname_str    nvarchar(13),
                        @current_nickname               int,
                        @current_artid                  uniqueidentifier,
                        @current_processing_order int,
                        @current_parent_rowguid uniqueidentifier,
                        @current_logical_record_lineage varbinary(311),
                        @use_partition_groups   smallint,
                        @actual_enumentirerowmetadata   bit,
                        @parent_in_contents bit
                        
    select @generation_clause1 = ' '
    select @generation_clause2 = ' ' 
    select @generation_clause3 = ' '
    
        set @actual_enumentirerowmetadata = @enumentirerowmetadata
   
    -- only PAL user or dbo have access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @partition_id = @partition_id
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    if (@parent_nickname is null)
    begin
        RAISERROR(14043, 16, -1, '@parent_nickname', 'sp_MSenum_logicalrecord_changes')
        return (1)
    end

    if (@genlist is null)
    begin
        RAISERROR(14043, 16, -1, '@genlist', 'sp_MSenum_logicalrecord_changes')
        return (1)
    end
    
    select @mingenstr = convert(nvarchar, @mingen)
    select @maxgenstr = convert(nvarchar, @maxgen)

    if (@maxgen = 0)
    begin
        select @generation_clause1 = ' mc.generation in ('
        select @generation_clause2 = rtrim(ltrim(@genlist))
        select @generation_clause3 = ') '
        select @maxgen_clause = ' '
        select @cpm_generation_clause = ' '
        select @cpm_maxgen_clause = ' '
    end
    else if @mingen = @maxgen
    begin
        select @generation_clause1 = ' mc.generation = ' + @mingenstr + ' '
        select @maxgen_clause = ' and mc.generation > ' + @maxgenstr
        select @cpm_generation_clause = ' and cpm.generation = ' + @mingenstr  
        select @cpm_maxgen_clause = ' and cpm.generation > ' + @maxgenstr
    end
    else
    begin
        select @generation_clause1 = ' mc.generation >= ' + @mingenstr + ' and mc.generation <= ' + @maxgenstr 
                                        + ' and mc.generation in ('
                select @generation_clause2 = rtrim(ltrim(@genlist))
                select @generation_clause3 = ') '
        select @maxgen_clause = ' and mc.generation > ' + @maxgenstr
        select @cpm_generation_clause = ' and cpm.generation >= ' + @mingenstr + ' and cpm.generation <= ' + @maxgenstr 
        select @cpm_maxgen_clause = ' and cpm.generation > ' + @maxgenstr
    end
        
    if @oldmaxgen > 0
    begin
        select @oldmaxgen_clause = ' and mc.generation <= ' + convert(nvarchar, @oldmaxgen)
        select @cpm_oldmaxgen_clause = ' and cpm.generation <= ' + convert(nvarchar, @oldmaxgen)
    end
    else
        begin
                select @oldmaxgen_clause = ' '
                select @cpm_oldmaxgen_clause = ' '
        end
                
        select @parent_nickname_str = convert(nvarchar, @parent_nickname)
        
        select top 1 @use_partition_groups = isnull(use_partition_groups,0)
        from dbo.sysmergepublications
        where pubid = @pubid

    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin
        if (@use_partition_groups <= 0)
        begin
            execute ('insert into #logical_record_changes 
                        select tablenick, rowguid, generation, lineage, colv1, logical_record_parent_rowguid, 1, NULL
                        from (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
						join dbo.MSmerge_contents mc 
							on mc.tablenick = nick.nickname
							and ' + @generation_clause1 + @generation_clause2 + @generation_clause3)
                                
            if @@error <> 0 return 1
            
            execute ('insert into #logical_record_changes 
                        select tablenick, rowguid, generation, lineage, NULL, logical_record_parent_rowguid, 0, type
                        from (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
						join dbo.MSmerge_tombstone mc
							on mc.tablenick = nick.nickname
							and ' + @generation_clause1 + @generation_clause2 + @generation_clause3)
                                
            if @@error <> 0 return 1

            execute ('insert into #logical_record_changes 
                        select mc.tablenick, mc.rowguid, mc.generation, mc.lineage, mc.colv1, mc.logical_record_parent_rowguid, 1, NULL
                        from (select distinct logical_record_parent_rowguid from #logical_record_changes) as lrprg
                        join dbo.MSmerge_contents mc
							on mc.logical_record_parent_rowguid = lrprg.logical_record_parent_rowguid
							' + @oldmaxgen_clause + @maxgen_clause + '
                        join (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
							on mc.tablenick = nick.nickname
						left outer join #logical_record_changes lrc
							on lrc.rowguid = mc.rowguid
							and lrc.tablenick = mc.tablenick
						where lrc.rowguid is null')

            if @@error <> 0 return 1
                            
            execute ('insert into #logical_record_changes 
                        select mc.tablenick, mc.rowguid, mc.generation, mc.lineage, NULL, mc.logical_record_parent_rowguid, 0, mc.type
                        from (select distinct logical_record_parent_rowguid from #logical_record_changes) as lrprg
                        join dbo.MSmerge_tombstone mc 
							on mc.logical_record_parent_rowguid = lrprg.logical_record_parent_rowguid
							' + @oldmaxgen_clause + @maxgen_clause + '
                        join (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
							on mc.tablenick = nick.nickname
						left outer join #logical_record_changes lrc
							on lrc.rowguid = mc.rowguid
							and lrc.tablenick = mc.tablenick
						where lrc.rowguid is null')
                                
            if @@error <> 0 return 1
        end
        else
        begin
        
            declare @partition_id_str               nvarchar(13),
                            @publication_number_str nvarchar(6)
            select top 1 @publication_number_str = convert(nvarchar(6),publication_number) from dbo.sysmergepublications where pubid = @pubid
            
            select @partition_id_str = convert(nvarchar, @partition_id)
    
            execute('insert into #logical_record_changes  
                        select distinct mc.tablenick, mc.rowguid, mc.generation, mc.lineage, mc.colv1, mc.logical_record_parent_rowguid, 1, NULL
                        from (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
						join dbo.MSmerge_contents mc 
							on mc.tablenick = nick.nickname
							and ' + @generation_clause1 + @generation_clause2 + @generation_clause3 + '
                        join dbo.MSmerge_current_partition_mappings cpm 
							on cpm.tablenick = mc.tablenick
							and cpm.rowguid = mc.rowguid
							and
							(
									(cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = ' + @publication_number_str + ') or
									(cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = 0) or
									(cpm.partition_id = -1 and cpm.publication_number = ' + @publication_number_str + ') or
									(cpm.partition_id = -1 and cpm.publication_number = 0)
							)')
                            
            if @@error <> 0 return 1
            
            execute('insert into #logical_record_changes  
                        select distinct mc.tablenick, mc.rowguid, mc.generation, mc.lineage, NULL, mc.logical_record_parent_rowguid, 0, mc.type
                        from (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
						join dbo.MSmerge_tombstone mc
							on mc.tablenick = nick.nickname
		                    and ' + @generation_clause1 + @generation_clause2 + @generation_clause3 + '
						join dbo.MSmerge_past_partition_mappings cpm
				            on cpm.tablenick = mc.tablenick
					        and cpm.rowguid = mc.rowguid ' +
					        @cpm_generation_clause + '
						    and
							(
	                            (cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = 0) or
								(cpm.partition_id = -1 and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = -1 and cpm.publication_number = 0)
							)')
                            
            if @@error <> 0 return 1
            
            execute('insert into #logical_record_changes  
                        select distinct mc.tablenick, mc.rowguid, mc.generation, mc.lineage, mc.colv1, mc.logical_record_parent_rowguid, 1, NULL
                        from (select distinct logical_record_parent_rowguid from #logical_record_changes) as lrprg
                        join dbo.MSmerge_contents mc
						   on mc.logical_record_parent_rowguid = lrprg.logical_record_parent_rowguid
                        join (select distinct nickname from dbo.sysmergepartitioninfoview 
									where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
							on mc.tablenick = nick.nickname
							' + @oldmaxgen_clause + @maxgen_clause + '
                        join dbo.MSmerge_current_partition_mappings cpm
							on cpm.tablenick = mc.tablenick
							and cpm.rowguid = mc.rowguid
							and
							(
	                            (cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = 0) or
								(cpm.partition_id = -1 and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = -1 and cpm.publication_number = 0)
							)
                        left outer join #logical_record_changes lrc
							on lrc.rowguid = mc.rowguid
							and lrc.tablenick = mc.tablenick
						where lrc.rowguid is null')
                                        
            if @@error <> 0 return 1
                            
            execute('insert into #logical_record_changes  
                        select distinct mc.tablenick, mc.rowguid, mc.generation, mc.lineage, NULL, mc.logical_record_parent_rowguid, 0, type
                        from (select distinct logical_record_parent_rowguid from #logical_record_changes) as lrprg
                        join dbo.MSmerge_tombstone mc
							on mc.logical_record_parent_rowguid = lrprg.logical_record_parent_rowguid
                        join (select distinct nickname from dbo.sysmergepartitioninfoview 
								where logical_record_parent_nickname = ' + @parent_nickname_str + ') as nick
							on mc.tablenick = nick.nickname
							' + @oldmaxgen_clause + @maxgen_clause + '
                        join dbo.MSmerge_past_partition_mappings cpm
							on cpm.tablenick = mc.tablenick
							and cpm.rowguid = mc.rowguid '
							+ @cpm_oldmaxgen_clause + @cpm_maxgen_clause + '
							and
							(
	                            (cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = ' + @partition_id_str + ' and cpm.publication_number = 0) or
								(cpm.partition_id = -1 and cpm.publication_number = ' + @publication_number_str + ') or
								(cpm.partition_id = -1 and cpm.publication_number = 0)
							)
                        left outer join #logical_record_changes lrc
							on lrc.rowguid = mc.rowguid
							and lrc.tablenick = mc.tablenick
						where lrc.rowguid is null')
                            
            if @@error <> 0 return 1
        end
    end
        
    set @current_parent_rowguid = '00000000-0000-0000-0000-000000000000'
    
    exec ('create index #logical_record_changes_index on #logical_record_changes (logical_record_parent_rowguid)')
    
    while exists (select * from #logical_record_changes
                                    where logical_record_parent_rowguid is not null
                                    and logical_record_parent_rowguid > @current_parent_rowguid)
    begin
        select @parent_in_contents = 1
        
        -- Of all the parent rowguids inserted into #logical_record_changes, process in asc order.
        select top 1 @current_parent_rowguid = logical_record_parent_rowguid
        from #logical_record_changes
        where logical_record_parent_rowguid is not null
        and logical_record_parent_rowguid > @current_parent_rowguid
        order by logical_record_parent_rowguid
        
        select @current_logical_record_lineage = NULL
        
        select @current_logical_record_lineage = logical_record_lineage
        from dbo.MSmerge_contents
        where rowguid = @current_parent_rowguid and tablenick = @parent_nickname
        
        if @current_logical_record_lineage is null
        begin
                select @current_logical_record_lineage = logical_record_lineage
                from dbo.MSmerge_tombstone
                where rowguid = @current_parent_rowguid and tablenick = @parent_nickname
                
                select @parent_in_contents = 0
        end
                
        select  logical_record_parent_nickname = @parent_nickname,
                        logical_record_parent_rowguid = @current_parent_rowguid,
                        logical_record_lineage = @current_logical_record_lineage,
                        logical_record_parent_in_contents = @parent_in_contents

        -- For this parent rowguid, find the child nicknames in processing order.
        select @current_nickname = 0, @current_artid = NULL, @current_processing_order = 0
        
        -- get the tombstone members in all cases - whether parent is in contents or tombstone.
        select lrc.tablenick, lrc.rowguid, lrc.generation, lrc.lineage, lrc.ts_type
        from #logical_record_changes lrc, dbo.sysmergearticles sma
        where logical_record_parent_rowguid = @current_parent_rowguid
        and sma.pubid = @pubid
        and lrc.tablenick = sma.nickname
        and lrc.iscontents = 0
        order by sma.processing_order desc, sma.nickname desc, lrc.rowguid asc
        
        -- get the contents members only if parent is in contents. if parent is in tombstone,
        -- then all members are guaranteed to be in tombstone.
        if @parent_in_contents = 1
        begin
            while exists (select lrc.tablenick from #logical_record_changes lrc, dbo.sysmergearticles sma
                                            where lrc.tablenick = sma.nickname
                                            and sma.pubid = @pubid
                                            and lrc.logical_record_parent_rowguid = @current_parent_rowguid
                                            and 
                                            (
                                                    (sma.processing_order = @current_processing_order and lrc.tablenick > @current_nickname) or
                                                    sma.processing_order > @current_processing_order
                                            )
                                    )
            begin
                truncate table #cont
                
                select top 1 @current_nickname = tablenick, @current_processing_order = processing_order,
                                        @current_artid = artid, @procname = 'dbo.' + select_proc
                from #logical_record_changes lrc, dbo.sysmergearticles sma
                where lrc.tablenick = sma.nickname
                and sma.pubid = @pubid
                and lrc.logical_record_parent_rowguid = @current_parent_rowguid
                and 
                (
                        (sma.processing_order = @current_processing_order and lrc.tablenick > @current_nickname) or
                        sma.processing_order > @current_processing_order
                )
                order by sma.processing_order, sma.nickname

                select @maxschemaguidforarticle = sys.fn_GetArticleSchemaVersionGuid(@current_artid, @pubid)
                insert into #cont (tablenick, rowguid, generation, lineage, colv1, logical_record_parent_rowguid) 
                select tablenick, rowguid, generation, lineage, colv1, logical_record_parent_rowguid 
                from #logical_record_changes
                where tablenick = @current_nickname
                and logical_record_parent_rowguid = @current_parent_rowguid
                
                -- if @enumentirerowmetadata is 1, then @actual_enumentirerowmetadata stays initialized to 1 from the
                -- beginning of the proc. Otherwise, we need to set @actual_enumentirerowmetadata for every article.
                if @enumentirerowmetadata = 0
                begin
                    select @actual_enumentirerowmetadata = sys.fn_MSarticle_allows_DML_at_this_replica(@current_artid, default)     
                end

                exec @retcode = @procname 
                                    @maxschemaguidforarticle = @maxschemaguidforarticle,
                                    @type= 10,
                                    @enumentirerowmetadata= @actual_enumentirerowmetadata
                
                IF @@ERROR<>0 or @retcode<>0
                begin
                    RETURN (1)
                end
            end
        end
    end

    drop table #logical_record_changes
    drop table #cont
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenum_logicalrecord_changes] TO [public] AS [dbo]
GO
