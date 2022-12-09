SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_can_tlog_be_applied]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_can_tlog_be_applied] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_can_tlog_be_applied]
	@backup_file_name [nvarchar](500),
	@database_name [sysname],
	@result [bit] OUTPUT,
	@verbose [bit]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
            ,@command nvarchar(1000)
            ,@backup_type int
            ,@backupdbname sysname
            ,@backup_first_lsn numeric(25,0)
            ,@backup_last_lsn numeric(25,0)
            ,@db_redo_start_lsn numeric(25,0)
    declare @backup_header table (
            BackupName             nvarchar(128)  NULL,
            BackupDescription      nvarchar(256)  NULL,
            BackupType             int,
            ExpirationDate         datetime NULL,
            Compressed             int,
            Position               int,
            DeviceType             int,
            UserName               nvarchar(128) NULL,
            ServerName             nvarchar(128),
            DatabaseName           nvarchar(128),
            DatabaseVersion        int,
            DatabaseCreationDate   datetime,
            BackupSize             numeric(20,0) NULL,
            FirstLsn               numeric(25,0) NULL,
            LastLsn                numeric(25,0) NULL,
            CheckpointLsn          numeric(25,0) NULL,
            DatabaseBackupLsn      numeric(25,0) NULL,
            BackupStartDate        datetime,
            BackupFinishDate       datetime,
            SortOrder              int,
            CodePage               int,
            UnicodeLocaleId        int,
            UnicodeComparisonStyle int,
            CompatibilityLevel     int,
            SoftwareVendorId       int,
            SoftwareVersionMajor   int,
            SoftwareVersionMinor   int,
            SoftwareVersionBuild   int,
            MachineName            nvarchar(128),
            Flags                  int NULL,
            BindingId              uniqueidentifier NULL,
            RecoveryForkId         uniqueidentifier NULL,
            Collation              nvarchar(128) null,
            FamilyGUID             uniqueidentifier null,
            HasBulkLoggedData      bit null,
            IsSnapshot             bit null,
            IsReadOnly             bit null,
            IsSingleUser           bit null,
            HasBackupChecksums     bit null,
            IsDamaged              bit null,
            BeginsLogChain         bit null,
            HasIncompleteMetadata  bit null,
            IsForceOffline         bit null,
            IsCopyOnly             bit null,
            FirstRecoveryForkID    uniqueidentifier null,
            ForkPointLSN           numeric(25,0) null,
            RecoveryModel          nvarchar(60) null,
            DifferentialBaseLSN    numeric(25,0) null,
            DifferentialBaseGUID   uniqueidentifier null,
            BackupTypeDescription  nvarchar(60) null,
            BackupSetGUID          uniqueidentifier null,
            CompressedBackupSize   numeric(20,0) null,
            Containment            tinyint NOT NULL,
            KeyAlgorithm           nvarchar(32) NULL,
            EncryptorThumbprint    varbinary(20)NULL,
            EncryptorType          nvarchar(32) NULL)

    --
    -- security check
    --
    exec @retcode = sys.sp_MSlogshippingsysadmincheck
    if (@retcode != 0 or @@error != 0)
        return 1
    --
    -- initialize
    --
    select @result = 0
    --
    -- get the backup information
    --
    select @command = N'restore headeronly from disk = N''' + replace(@backup_file_name, N'''',N'''''') + N''''
    insert into @backup_header
        execute(@command)
    if (@@error != 0)
        return 1
    --
    -- get the redo start lsn for the database
    -- choose the smallest value from all of the files of the database being restored
    -- State 0 is "online", so this handles page restore, or cases where the "restoring" state isn't marked properly.
    -- State 1 is "restoring", which is the expected state.
    -- redo_start_lsn is null for files which are not subject to restore.
    --
    select @db_redo_start_lsn = min(redo_start_lsn)
    from master.sys.master_files
    where database_id = db_id (@database_name)
        and type = 0
        and state in (0,1)
        and redo_start_lsn is not null

    if (@db_redo_start_lsn is null)
    begin
        --
        -- the log can not be restored
        --
        return 0
    end  -- if (@db_redo_start_lsn is null)

    if (@verbose = 1)
    begin
        raiserror('The redo start LSN for the database is:', 10, 1)
        select @db_redo_start_lsn
    end
    --
    -- Get the first LSN from backup header
    -- Will need the other info for old method
    --
    select top 1 @backupdbname = DatabaseName
                    ,@backup_first_lsn = ISNULL(FirstLsn, 0)
                    ,@backup_last_lsn = ISNULL(LastLsn, 0)
                    ,@backup_type = BackupType
    from @backup_header
    if (@verbose = 1)
    begin
        raiserror(N'The backup details (FirstLSN, LastLSN, BackupType, DatabaseName) :', 10, 1)
        select @backup_first_lsn, @backup_last_lsn, @backup_type, @backupdbname
    end
    --
    -- Basic sanity checks
    --
    if (@backupdbname != @database_name)
    begin
        raiserror(14418,10,1, @database_name)
    end
    if (@backup_type not in (1,2))
    begin
        raiserror(14419,-1,-1)
        return (1) -- Failure
    end
    --
    -- We can apply the backup if the
    -- backup_first_lsn <= db_redo_start_lsn < backup_last_lsn
    -- In strict sense - we can apply the backup if db_redo_start_lsn
    -- is equal to backup_last_lsn, however no pages will be restored
    -- The aim is to pick one log file that will satisfy the criterion for
    -- applying restore
    --
    if (@db_redo_start_lsn >= @backup_first_lsn and @db_redo_start_lsn < @backup_last_lsn)
        select @result = 1
    --
    -- all done
    --
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_can_tlog_be_applied] TO [public] AS [dbo]
GO
