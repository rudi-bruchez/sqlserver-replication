SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpsubscription_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpsubscription_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpsubscription_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
    DECLARE @retcode int,
    		@fpullsubexists bit

	SELECT @fpullsubexists = 0
    /*
    ** Security Check
    */

    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)

    -- Check the publication_type value if it is not NULL
    IF @publication_type is not NULL
        and @publication_type not in (0, 1, 2)
    BEGIN
        declare @val varchar(20)

        select @val = cast(@publication_type as varchar)

        -- '%s' is not a valid value for the '%s' parameter. The value must be 0, 1, or 2.
        raiserror(21117, 16, -1, @val, '@publication_type')

        RETURN(1)
    END
    
    /*
    ** The logic is added here for the case where MSsubscription_properties table does not exist
    ** or relevant entry is not added because sp_addmergepullsubscription_agent or sp_addsubscription_agent
    ** is not called.
    */
    IF object_id('MSsubscription_properties','U') is NULL
    begin
        return (0)
    end
    
    IF (@publisher IS NULL) OR (@publisher = '')
        select @publisher = '%'
    IF (@publisher_db IS NULL) OR (@publisher_db = '')
        select @publisher_db = '%'
    IF (@publication IS NULL) OR (@publication = '')
        select @publication = '%'

    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

	IF object_id('MSreplication_subscriptions','U') IS NOT NULL
	BEGIN
		-- tran
		IF EXISTS(SELECT *
					FROM MSreplication_subscriptions
					WHERE subscription_type != 0)
		BEGIN
			SELECT @fpullsubexists = 1
		END
	END

	IF object_id('sysmergesubscriptions','U') IS NOT NULL
	BEGIN
		-- Merge
		IF EXISTS(SELECT *
				FROM sysmergesubscriptions
				WHERE subscription_type != 0)
		BEGIN
			SELECT @fpullsubexists = 1
		END
	END
	
    IF @publication_type IS NOT NULL
    BEGIN
        SELECT publisher, publisher_db, publication, publication_type, publisher_login,
               sys.fn_repldecryptver4(publisher_password), publisher_security_mode, distributor, distributor_login,
               sys.fn_repldecryptver4(distributor_password), distributor_security_mode, 'ftp_address' = null, 'ftp_port' = 0,
               'ftp_login' = null, 'ftp_password' = null, alt_snapshot_folder, working_directory, use_ftp,
               dts_package_name, sys.fn_repldecryptver4(dts_package_password), dts_package_location, 
               offload_agent, offload_server, dynamic_snapshot_location, use_web_sync, internet_url,
               internet_login, sys.fn_repldecryptver4(internet_password), internet_security_mode, internet_timeout, hostname,
               job_login, 'job_password' = sys.fn_repldecryptver4(job_password)
          FROM MSsubscription_properties
         WHERE ((@publisher = N'%') OR (UPPER(publisher) = UPPER(@publisher)))
           AND ((@publisher_db = N'%') or ( publisher_db = @publisher_db))
           AND publication LIKE @publication
           AND publication_type = @publication_type
    END
    ELSE
    BEGIN
        SELECT publisher, publisher_db, publication, publication_type, publisher_login,
               sys.fn_repldecryptver4(publisher_password), publisher_security_mode, distributor, distributor_login,
               sys.fn_repldecryptver4(distributor_password), distributor_security_mode, 'ftp_address' = null, 'ftp_port' = 0,
               'ftp_login' = null, 'ftp_password' = null, alt_snapshot_folder, working_directory, use_ftp,
               dts_package_name, sys.fn_repldecryptver4(dts_package_password), dts_package_location,
               offload_agent, offload_server, dynamic_snapshot_location, use_web_sync, internet_url,
               internet_login, sys.fn_repldecryptver4(internet_password), internet_security_mode, internet_timeout, hostname,
               job_login, 'job_password' = sys.fn_repldecryptver4(job_password)
          FROM MSsubscription_properties
         WHERE ((@publisher = N'%') OR (UPPER(publisher) = UPPER(@publisher)))
           AND ((@publisher_db = N'%') or ( publisher_db = @publisher_db))
           AND publication LIKE @publication
    END
	
    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_helpsubscription_properties] TO [public] AS [dbo]
GO
