-- Removes what prof-setup.sql creates; idempotent. The publication goes
-- first: a profile in use cannot be dropped.
SET NOCOUNT ON;
USE master;
DECLARE @errors nvarchar(max) = N'';
BEGIN TRY
    IF EXISTS (SELECT 1 FROM Sales.dbo.syspublications WHERE name = N'm_prof')
        EXEC Sales.sys.sp_droppublication @publication = N'm_prof';
END TRY
BEGIN CATCH
    SET @errors += N'sp_droppublication: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    IF OBJECT_ID(N'Sales.dbo.m_pft1') IS NOT NULL
        EXEC Sales.sys.sp_executesql N'DROP TABLE dbo.m_pft1';
END TRY
BEGIN CATCH
    SET @errors += N'DROP TABLE dbo.m_pft1: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
BEGIN TRY
    DECLARE @pid int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_prof_snap' AND agent_type = 1);
    IF @pid IS NOT NULL
        EXEC distribution.dbo.sp_drop_agent_profile @profile_id = @pid;
END TRY
BEGIN CATCH
    SET @errors += N'sp_drop_agent_profile: ' + ERROR_MESSAGE() + NCHAR(10);
END CATCH;
IF @errors <> N''
    THROW 50000, @errors, 1;
