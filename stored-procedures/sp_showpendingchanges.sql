SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_showpendingchanges]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_showpendingchanges] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_showpendingchanges]
	@destination_server [sysname],
	@publication [sysname],
	@article [sysname],
	@show_rows [int]
WITH EXECUTE AS CALLER
AS
declare @current_destination_server sysname
    declare @destination_db_name         sysname
    declare @is_dest_subscriber         bit
    declare @pub_name                     sysname
    declare @pubid                         uniqueidentifier
    declare @sentgen                     bigint
    declare @partition_id                 int
    declare @article_name                 sysname
    declare @tablenick                     int
    declare @replnickname                 binary(6)
    declare @use_partition_groups         smallint

    declare @pending_deletes             int
    declare @pending_partition_deletes   int
    declare @pending_ins_and_upd         int
    declare @retcode                    int

    -- Security Check
    exec @retcode= sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)

    declare @result_table TABLE (
        destination_server         sysname, 
        pub_name                 sysname, 
        destination_db_name     sysname,
        is_dest_subscriber         bit, 
        article_name             sysname,
        pending_deletes         int, 
        pending_ins_and_upd     int,
        is_delete				int,
        rowguid					uniqueidentifier)


    declare #serv_pub_art cursor local fast_forward for
        select
        sms.subscriber_server,
        smp.name,
        sms.db_name,
        sys.fn_MSmerge_islocalpubid(smp.pubid),
        sma.name,
        sma.nickname,
        smp.use_partition_groups,
        sms.sentgen,
        sms.replnickname,
        sms.partition_id
        from
        (sysmergepublications smp with (nolock)
        JOIN sysmergearticles sma with (nolock)
        ON smp.pubid = sma.pubid)
        JOIN sysmergesubscriptions sms with (nolock)
        ON smp.pubid = sms.pubid and db_name() <> sms.db_name
        order by sms.subscriber_server, smp.name, sma.name asc

    open #serv_pub_art
    fetch #serv_pub_art into
        @current_destination_server,
        @pub_name,
        @destination_db_name,
        @is_dest_subscriber,
        @article_name,
        @tablenick,
        @use_partition_groups,
        @sentgen,
        @replnickname,
        @partition_id

    while (@@fetch_status != -1)
    begin

		select @pending_deletes = 0
		select @pending_ins_and_upd = 0

        if    (@destination_server IS NULL or @destination_server = @current_destination_server) and
            (@publication IS NULL or @publication = @pub_name) and 
            (@article IS NULL or @article = @article_name)
        begin
            if @use_partition_groups = 1 and @partition_id IS NOT NULL
            begin
                /* Calculate pending deletes based on water marks */
                select @pending_deletes = count(*) from 
                (MSmerge_genhistory gh with (nolock)
                JOIN MSmerge_tombstone ts with (nolock)
                ON gh.generation = ts.generation)
                    JOIN MSmerge_past_partition_mappings ppm with (nolock)
                    ON ts.rowguid = ppm.rowguid and ts.generation = ppm.generation
                where    gh.art_nick = @tablenick and 
                        gh.generation > @sentgen and
                        ppm.partition_id = @partition_id  and
                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0

                /* Calculate pending partitiondeletes based on water marks */
                select @pending_partition_deletes = count(*) from 
                MSmerge_genhistory gh with (nolock)
                JOIN MSmerge_past_partition_mappings ppm with (nolock)
                    ON gh.generation = ppm.generation
                    LEFT OUTER JOIN MSmerge_tombstone ts with (nolock)
                    ON ts.rowguid = ppm.rowguid
                where    gh.art_nick = @tablenick and 
                        gh.generation > @sentgen and
                        ts.rowguid is null and
                        ppm.partition_id = @partition_id and
                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0
                        
				select @pending_deletes = @pending_deletes + @pending_partition_deletes

				if @show_rows = 1
				begin
					insert into 
					@result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd, is_delete, rowguid)
					select @current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, 0, 0, 1,
						ts.rowguid from 
						(MSmerge_genhistory gh with (nolock)
						JOIN MSmerge_tombstone ts with (nolock)
						ON gh.generation = ts.generation)
							JOIN MSmerge_past_partition_mappings ppm with (nolock)
							ON ts.rowguid = ppm.rowguid and ts.generation = ppm.generation
						where    gh.art_nick = @tablenick and 
								gh.generation > @sentgen and
								ppm.partition_id = @partition_id and
		                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0
		                    


					insert into 
					@result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd, is_delete, rowguid)
					select @current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, 0, 0, 1,
						ppm.rowguid from 
						MSmerge_genhistory gh with (nolock)
						JOIN MSmerge_past_partition_mappings ppm with (nolock)
							ON gh.generation = ppm.generation
							LEFT OUTER JOIN MSmerge_tombstone ts with (nolock)
							ON ts.rowguid = ppm.rowguid
							where gh.art_nick = @tablenick and 
								gh.generation > @sentgen and
								ts.rowguid is null and
								ppm.partition_id = @partition_id and
		                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0

				end

                /* Calculate pending updates and inserts based on water marks */
                select @pending_ins_and_upd = count(*) from 
                (MSmerge_genhistory gh with (nolock)
                JOIN MSmerge_contents mc with (nolock)
                ON gh.generation = mc.generation)
                    JOIN MSmerge_current_partition_mappings cpm with (nolock)
                    ON mc.rowguid = cpm.rowguid
                where    gh.art_nick = @tablenick and 
                        gh.generation > @sentgen and
                        cpm.partition_id = @partition_id and
                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0

				if @show_rows = 1
				begin

					insert into 
					@result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd, is_delete, rowguid)
					select @current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, 0,0,0,
						mc.rowguid from 
						(MSmerge_genhistory gh with (nolock)
						JOIN MSmerge_contents mc with (nolock)
						ON gh.generation = mc.generation)
							JOIN MSmerge_current_partition_mappings cpm with (nolock)
							ON mc.rowguid = cpm.rowguid
						where    gh.art_nick = @tablenick and 
								gh.generation > @sentgen and
								cpm.partition_id = @partition_id and
		                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0
				end
                        
            end
            else
            begin

                /* Calculate pending deletes based on water marks */
                select @pending_deletes = count(*) from 
                MSmerge_genhistory gh with (nolock) 
                JOIN MSmerge_tombstone ts with (nolock)
                ON gh.generation = ts.generation
                where    gh.art_nick = @tablenick and 
                        gh.generation > @sentgen and
                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0

				if @show_rows = 1
				begin
					insert into 
					@result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd, is_delete, rowguid)
					select @current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, 0, 0,1, 
						ts.rowguid from 
						MSmerge_genhistory gh with (nolock) 
						JOIN MSmerge_tombstone ts with (nolock)
						ON gh.generation = ts.generation
						where    gh.art_nick = @tablenick and 
								gh.generation > @sentgen and
								sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0
				end

                /* Calculate pending updates and inserts based on water marks */
                select @pending_ins_and_upd = count(*) from 
                MSmerge_genhistory gh with (nolock)
                JOIN MSmerge_contents mc with (nolock)
                ON gh.generation = mc.generation
                where    gh.art_nick = @tablenick and 
                        gh.generation > @sentgen and
                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0


				if @show_rows = 1
				begin
					insert into 
					@result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd, is_delete, rowguid)
					select @current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, 0, 0, 0,
						mc.rowguid from 
						MSmerge_genhistory gh with (nolock)
						JOIN MSmerge_contents mc with (nolock)
						ON gh.generation = mc.generation
						where    gh.art_nick = @tablenick and 
								gh.generation > @sentgen and
		                        sys.fn_MSmerge_nicknamefound(gh.nicknames,@replnickname) = 0
				end
				
            end

			if @show_rows = 0
			begin                        
	            insert into 
	            @result_table(destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd)
	            values (@current_destination_server, @pub_name, @destination_db_name, @is_dest_subscriber, @article_name, @pending_deletes, @pending_ins_and_upd)
	        end
        end
        fetch #serv_pub_art into
            @current_destination_server,
            @pub_name,
            @destination_db_name,
            @is_dest_subscriber,
            @article_name,
            @tablenick,
            @use_partition_groups,
            @sentgen,
            @replnickname,
            @partition_id
    end
    close #serv_pub_art   
    deallocate #serv_pub_art

	if @show_rows = 1
	    select destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, is_delete, rowguid from @result_table order by destination_server, pub_name, destination_db_name, article_name asc
	else
	    select destination_server,pub_name, destination_db_name, is_dest_subscriber,article_name, pending_deletes, pending_ins_and_upd from @result_table order by destination_server, pub_name, destination_db_name, article_name asc

    return 0
GO
GRANT EXECUTE ON [sys].[sp_showpendingchanges] TO [public] AS [dbo]
GO
