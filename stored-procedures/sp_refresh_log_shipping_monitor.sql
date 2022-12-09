SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_refresh_log_shipping_monitor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_refresh_log_shipping_monitor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_refresh_log_shipping_monitor]
	@agent_id [uniqueidentifier],
	@agent_type [tinyint],
	@database [sysname],
	@mode [tinyint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@agent_idstring sysname
                ,@monitor_server sysname
                ,@monitor_server_security_mode int
                ,@linkcmd nvarchar(4000)
                ,@istrustworthyset bit
    --
    -- security check
    --
    exec @retcode = sys.sp_MSlogshippingsysadmincheck
    if (@retcode != 0 or @@error != 0)
        return 1
    --
    -- validate agent_type
    --
    if (@agent_type not in (0,1,2))
    begin
        raiserror(21055, 16, -1, '@agent_type','sp_refresh_log_shipping_monitor')
        return 1
    end
    --
    -- validate mode
    --
    if (@mode not in (1,2))
    begin
        raiserror(21055, 16, -1, '@mode','sp_refresh_log_shipping_monitor')
        return 1
    end
    --
    -- must be invoked from master db
    --
    if (db_name() != N'master')
    begin
        raiserror(5001, 16,-1)
        return 1
    end
    --
    -- validate agent
    --
    if (sys.fn_MSvalidatelogshipagentid(@agent_id, @agent_type) = 0)
    begin
        select @agent_idstring = cast(@agent_id as sysname)
        raiserror(32016, 16, 1, @agent_idstring, @agent_type)
        return 1
    end
    --
    -- if database is supplied - validate it
    --
    if (@database is not null)
    begin
        if (@agent_type = 0) and not exists (select *
                from msdb.dbo.log_shipping_primary_databases
                where primary_database = @database
                    and primary_id = @agent_id)
        begin
            raiserror(32010, 16, 2, @database)
            return 1
        end
        else if (@agent_type in (1,2)) and not exists (select *
                from msdb.dbo.log_shipping_secondary_databases as sd
                    join msdb.dbo.log_shipping_secondary as s
                    on sd.secondary_id = s.secondary_id
                where sd.secondary_database = @database
                    and s.secondary_id = @agent_id)
        begin
            raiserror(32014, 16, 3, @database)
            return 1
        end
    end
    --
    -- get monitor server information
    --
    if (@agent_type = 0)
    begin
        select @monitor_server = monitor_server
                    ,@monitor_server_security_mode = monitor_server_security_mode
        from msdb.dbo.log_shipping_primary_databases
        where primary_id = @agent_id
    end
    else
    begin
        select @monitor_server = monitor_server
                    ,@monitor_server_security_mode = monitor_server_security_mode
        from msdb.dbo.log_shipping_secondary
        where secondary_id = @agent_id
    end
    --
    -- for local monitor - no need do anything
    --
    if (upper(@monitor_server) = upper(@@servername))
        return 0
    --
    -- The monitor is not local - check for impersonation
    --
    select @retcode = 0
    if (@monitor_server_security_mode = 0) and (suser_name() != SUSER_SNAME(0x01))
    begin
        --
        -- execute using proxy
        --
        exec @retcode = sys.sp_MSproxylogshippingmonitorrefresh
                    @agent_id = @agent_id
                    ,@agent_type = @agent_type
                    ,@database = @database
                    ,@mode = @mode
                    ,@monitor_server = @monitor_server
    end
    else
    begin
        --
        -- cleanup metadata first
        --
        if (@agent_type = 0)
        begin
            --
            -- delete Primary monitor data
            --
            select @linkcmd = quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.sys.sp_processlogshippingmonitorprimary'
            begin try
                exec @retcode = @linkcmd @mode = 2
                                        ,@primary_id = @agent_id
                                        ,@primary_server = @@servername
                                        ,@monitor_server = @monitor_server
                                        ,@monitor_server_security_mode = @monitor_server_security_mode
            end try
            begin catch
                select @retcode = 1
            end catch
        end
        else
        begin
            --
            -- delete Secondary monitor data
            --
            select @linkcmd = quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.sys.sp_processlogshippingmonitorsecondary'
            begin try
                exec @retcode = @linkcmd @mode = 2
                    ,@secondary_server = @@servername
                    ,@secondary_database = @database
                    ,@secondary_id = @agent_id
                    ,@monitor_server = @monitor_server
                    ,@monitor_server_security_mode = @monitor_server_security_mode
            end try
            begin catch
                select @retcode = 1
            end catch
        end
        if (@retcode != 0 or @@error != 0)
            goto cleanup
        --
        -- If we deleting - then we are done
        --
        if (@mode = 2)
            goto cleanup
        --
        -- refresh now
        --
        if (@agent_type = 0)
        begin
            --
            -- refresh primary data
            --
            select @linkcmd = N'insert into ' + quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.dbo.log_shipping_monitor_primary '
                + N'(primary_id,primary_server,primary_database,backup_threshold,threshold_alert,threshold_alert_enabled,last_backup_file,last_backup_date,last_backup_date_utc,history_retention_period) '
                + N'select primary_id,primary_server,primary_database,backup_threshold,threshold_alert,threshold_alert_enabled,last_backup_file,last_backup_date,last_backup_date_utc,history_retention_period '
                + N'from msdb.dbo.log_shipping_monitor_primary where primary_id = N''' + CAST(@agent_id as nvarchar(50)) +  ''' '
            begin try
                EXEC(@linkcmd)
            end try
            begin catch
                select @retcode = 1
            end catch
        end
        else
        begin
            --
            -- refresh secondary data
            --
            select @linkcmd = N'insert into ' + quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.dbo.log_shipping_monitor_secondary '
                + N'(secondary_server,secondary_database,secondary_id,primary_server,primary_database,restore_threshold,threshold_alert,threshold_alert_enabled'
                + N',last_copied_file,last_copied_date, last_copied_date_utc, last_restored_file,last_restored_date, last_restored_date_utc, last_restored_latency, history_retention_period) '
                + N'select secondary_server,secondary_database,secondary_id,primary_server,primary_database,restore_threshold,threshold_alert,threshold_alert_enabled'
                + N',last_copied_file,last_copied_date, last_copied_date_utc, last_restored_file,last_restored_date, last_restored_date_utc, last_restored_latency, history_retention_period '
                + N'from msdb.dbo.log_shipping_monitor_secondary where secondary_server = @@servername and '
                + N'secondary_id = N''' + CAST(@agent_id as nvarchar(50)) +  ''' '
                IF (@database is not null)
                BEGIN
                    SELECT @linkcmd = @linkcmd + N'and secondary_database = ''' + sys.fn_replreplacesinglequote(CAST(@database as nvarchar(128))) + ''' '
                END
            begin try
                EXEC(@linkcmd)
            end try
            begin catch
                select @retcode = 1
            end catch
        end
        if @@error != 0 OR @retcode != 0
            goto cleanup
        --
        -- refresh history
        --
        select @linkcmd = N'insert into ' + quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.dbo.log_shipping_monitor_history_detail '
            + N'(agent_id,agent_type,session_id,database_name,session_status,log_time,log_time_utc,message) '
            + N'select agent_id,agent_type,session_id,database_name,session_status,log_time,log_time_utc,message '
            + N'from msdb.dbo.log_shipping_monitor_history_detail where agent_id = N''' + CAST(@agent_id as nvarchar(50)) +  ''' '
        begin try
            EXEC(@linkcmd)
        end try
        begin catch
            select @retcode = 1
        end catch
        if @@error != 0 OR @retcode != 0
            goto cleanup
        --
        -- refresh error
        --
        select @linkcmd = N'insert into ' + quotename(sys.fn_MSgetlogshippingmoniterlinkname(upper(@monitor_server))) + N'.msdb.dbo.log_shipping_monitor_error_detail '
            + N'(agent_id,agent_type,session_id,database_name,sequence_number,log_time,log_time_utc,message,source,help_url) '
            + N'select agent_id,agent_type,session_id,database_name,sequence_number,log_time,log_time_utc,message,source,help_url '
            + N'from msdb.dbo.log_shipping_monitor_error_detail where agent_id = N''' + CAST(@agent_id as nvarchar(50)) +  ''' '
        begin try
            EXEC(@linkcmd)
        end try
        begin catch
            select @retcode = 1
        end catch
    end -- no proxy execution

cleanup:

    --
    -- all done
    --
    if (@retcode = 0)
        return 0
    else
    begin
        raiserror(32055, 16, 2)
        return 1
    end
end
GO
GRANT EXECUTE ON [sys].[sp_refresh_log_shipping_monitor] TO [public] AS [dbo]
GO
