-- Agent profile changes (plan 3, Task 3; read by the cost table and by Ruling R6): what
-- sp_add_agent_profile copies into a new profile, and which changes of a profile and of
-- its parameters the procedures accept. Run through lab/campaign.sh, from master.
-- Each case creates the distribution profile m_prof (sp_add_agent_profile with
-- @agent_type = 3, @profile_type = 1 and nothing else) inside its own transaction, runs
-- its call, reads back what changed in msdb.dbo.MSagent_profiles and MSagent_parameters,
-- and rolls back. PF.create_default and PF.copy_after_user_default share one transaction:
-- the second needs the user profile made the default by the first.
-- The template of a type is MIN(profile_id) of its system profiles (agent_type = 3,
-- type = 0), which sp_add_agent_profile copies (stored-procedures/sp_add_agent_profile.sql).
-- Rows: R|PF.<case>|ok, rc<n> (returned n without an error) or the error number|detail.
-- An error's detail names the step that raised it. No cleanup: nothing is committed, and
-- a profile left behind is residue that campaign.sh reports.
SET NOCOUNT ON;
USE master;
GO
DECLARE @r TABLE (n int IDENTITY, id varchar(60), result nvarchar(200), detail nvarchar(1000));
DECLARE @tpl int = (SELECT MIN(profile_id) FROM msdb.dbo.MSagent_profiles WHERE agent_type = 3 AND type = 0);
DECLARE @def int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE agent_type = 3 AND def_profile = 1);
DECLARE @tpl_names nvarchar(4000) = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @tpl);
DECLARE @tpl_set nvarchar(4000) = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name + N'=' + ISNULL(value, N'')), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @tpl);
DECLARE @p int, @p2 int, @p3 int, @rc int, @step nvarchar(60), @names nvarchar(4000), @set nvarchar(4000), @set2 nvarchar(4000);

-- PF.copied_parameters: the parameters of a new profile against those of the template.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC @rc = sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @names = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p);
    SET @set = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name + N'=' + ISNULL(value, N'')), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p);
    INSERT @r (id, result, detail)
    SELECT 'PF.copied_parameters', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'm_prof n=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p),
                  N' type=', (SELECT type FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p),
                  N' def_profile=', (SELECT def_profile FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p),
                  N'; template ', (SELECT profile_name FROM msdb.dbo.MSagent_profiles WHERE profile_id = @tpl),
                  N' (MIN(profile_id) agent_type 3 type 0, ', CASE WHEN @tpl = @def THEN N'also' ELSE N'not' END, N' the def_profile)',
                  N' n=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @tpl),
                  N'; same names=', CASE WHEN @names = @tpl_names THEN N'yes' ELSE N'no' END,
                  N' same values=', CASE WHEN @set = @tpl_set THEN N'yes' ELSE N'no' END,
                  N'; ', @set);
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.copied_parameters', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.change_missing_parameter: sp_change_agent_parameter of a name m_prof lacks.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_change_agent_parameter -PacketSize';
    EXEC @rc = sp_change_agent_parameter @profile_id = @p, @parameter_name = N'-PacketSize', @parameter_value = N'8192';
    INSERT @r (id, result, detail)
    SELECT 'PF.change_missing_parameter', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_change_agent_parameter -PacketSize = 8192 on m_prof: return code=', @rc,
                  N' -PacketSize rows=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p AND parameter_name = N'-PacketSize'),
                  N' parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.change_missing_parameter', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.change_description: sp_change_agent_profile description.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_change_agent_profile description';
    EXEC @rc = sp_change_agent_profile @profile_id = @p, @property = N'description', @value = N'm_changed';
    INSERT @r (id, result, detail)
    SELECT 'PF.change_description', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_change_agent_profile description = m_changed on m_prof: MSagent_profiles.description=',
                  ISNULL((SELECT CONVERT(nvarchar(400), description) FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p), N'null'));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.change_description', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.change_parameter: sp_change_agent_parameter of a copied name.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_change_agent_parameter -CommitBatchSize';
    EXEC @rc = sp_change_agent_parameter @profile_id = @p, @parameter_name = N'-CommitBatchSize', @parameter_value = N'200';
    INSERT @r (id, result, detail)
    SELECT 'PF.change_parameter', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_change_agent_parameter -CommitBatchSize = 200 on m_prof: MSagent_parameters.value=',
                  ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(400), ISNULL(value, N'null')), N',') FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p AND parameter_name = N'-CommitBatchSize'), N'no row'),
                  N' parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.change_parameter', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.add_parameter: a name of another system distribution profile that the template has not.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_add_agent_parameter -PacketSize';
    EXEC @rc = sp_add_agent_parameter @profile_id = @p, @parameter_name = N'-PacketSize', @parameter_value = N'8192';
    INSERT @r (id, result, detail)
    SELECT 'PF.add_parameter', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_add_agent_parameter -PacketSize = 8192 on m_prof: MSagent_parameters.value=',
                  ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(400), ISNULL(value, N'null')), N',') FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p AND parameter_name = N'-PacketSize'), N'no row'),
                  N' parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p),
                  N'; in the template: ', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @tpl AND parameter_name = N'-PacketSize'),
                  N', in system distribution profiles: ', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters x JOIN msdb.dbo.MSagent_profiles y ON y.profile_id = x.profile_id WHERE y.agent_type = 3 AND y.type = 0 AND x.parameter_name = N'-PacketSize'));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.add_parameter', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.add_copied_parameter: sp_add_agent_parameter of a name the copy already has.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_add_agent_parameter -CommitBatchSize';
    EXEC @rc = sp_add_agent_parameter @profile_id = @p, @parameter_name = N'-CommitBatchSize', @parameter_value = N'200';
    INSERT @r (id, result, detail)
    SELECT 'PF.add_copied_parameter', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_add_agent_parameter -CommitBatchSize = 200 on m_prof: MSagent_parameters.value=',
                  ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(400), ISNULL(value, N'null')), N',') FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p AND parameter_name = N'-CommitBatchSize'), N'no row'),
                  N' parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.add_copied_parameter', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.drop_parameter: sp_drop_agent_parameter of a copied name.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_drop_agent_parameter -QueryTimeout';
    EXEC @rc = sp_drop_agent_parameter @profile_id = @p, @parameter_name = N'-QueryTimeout';
    INSERT @r (id, result, detail)
    SELECT 'PF.drop_parameter', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_drop_agent_parameter -QueryTimeout on m_prof: -QueryTimeout rows=',
                  (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p AND parameter_name = N'-QueryTimeout'),
                  N' parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.drop_parameter', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.create_default, then PF.copy_after_user_default in the same transaction: a user
-- profile created as the default, its -CommitBatchSize changed to 300, then a third
-- profile created: does it copy the template or the new default?
DECLARE @done8 bit = 0;
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_add_agent_profile m_prof_def @default = 1'; SET @p2 = NULL;
    EXEC @rc = sp_add_agent_profile @profile_id = @p2 OUTPUT, @profile_name = N'm_prof_def', @agent_type = 3, @profile_type = 1, @default = 1;
    INSERT @r (id, result, detail)
    SELECT 'PF.create_default', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_add_agent_profile m_prof_def @default = 1: m_prof_def def_profile=', (SELECT def_profile FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p2),
                  N', ', (SELECT profile_name FROM msdb.dbo.MSagent_profiles WHERE profile_id = @def), N' (the default before) def_profile=',
                  (SELECT def_profile FROM msdb.dbo.MSagent_profiles WHERE profile_id = @def),
                  N', profiles with def_profile = 1 for agent_type 3: ', (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE agent_type = 3 AND def_profile = 1),
                  N', m_prof_def parameters=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p2));
    SET @done8 = 1;
    SET @step = N'sp_change_agent_parameter m_prof_def -CommitBatchSize';
    EXEC sp_change_agent_parameter @profile_id = @p2, @parameter_name = N'-CommitBatchSize', @parameter_value = N'300';
    SET @step = N'sp_add_agent_profile m_prof3'; SET @p3 = NULL;
    EXEC @rc = sp_add_agent_profile @profile_id = @p3 OUTPUT, @profile_name = N'm_prof3', @agent_type = 3, @profile_type = 1;
    SET @set = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name + N'=' + ISNULL(value, N'')), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p3);
    SET @set2 = (SELECT STRING_AGG(CONVERT(nvarchar(4000), parameter_name + N'=' + ISNULL(value, N'')), N' ') WITHIN GROUP (ORDER BY parameter_name) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p2);
    INSERT @r (id, result, detail)
    SELECT 'PF.copy_after_user_default', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_add_agent_profile m_prof3 with m_prof_def the default (-CommitBatchSize=',
                  (SELECT value FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p2 AND parameter_name = N'-CommitBatchSize'),
                  N'): m_prof3 n=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p3),
                  N' -CommitBatchSize=', ISNULL((SELECT value FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p3 AND parameter_name = N'-CommitBatchSize'), N'no row'),
                  N'; equal to the template=', CASE WHEN @set = @tpl_set THEN N'yes' ELSE N'no' END,
                  N' equal to m_prof_def=', CASE WHEN @set = @set2 THEN N'yes' ELSE N'no' END);
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES (CASE WHEN @done8 = 1 THEN 'PF.copy_after_user_default' ELSE 'PF.create_default' END,
        CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
    IF @done8 = 0
        INSERT @r (id, result, detail) VALUES ('PF.copy_after_user_default', N'not-run', N'PF.create_default failed in the same transaction');
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.change_default: sp_change_agent_profile default.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_change_agent_profile default';
    EXEC @rc = sp_change_agent_profile @profile_id = @p, @property = N'default', @value = N'1';
    INSERT @r (id, result, detail)
    SELECT 'PF.change_default', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_change_agent_profile default = 1 on m_prof: m_prof def_profile=', (SELECT def_profile FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p),
                  N', profiles with def_profile = 1 for agent_type 3: ', (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE agent_type = 3 AND def_profile = 1));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.change_default', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

-- PF.drop_unused: sp_drop_agent_profile of a profile no agent uses.
BEGIN TRY
    BEGIN TRAN;
    SET @step = N'sp_add_agent_profile m_prof'; SET @p = NULL;
    EXEC sp_add_agent_profile @profile_id = @p OUTPUT, @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1;
    SET @step = N'sp_drop_agent_profile m_prof';
    EXEC @rc = sp_drop_agent_profile @profile_id = @p;
    INSERT @r (id, result, detail)
    SELECT 'PF.drop_unused', CASE WHEN @rc = 0 THEN N'ok' ELSE N'rc' + CONVERT(nvarchar(10), @rc) END,
           CONCAT(N'sp_drop_agent_profile m_prof: MSagent_profiles rows=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_id = @p),
                  N' MSagent_parameters rows=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id = @p));
    ROLLBACK;
END TRY BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT @r (id, result, detail) VALUES ('PF.drop_unused', CONVERT(nvarchar(10), ERROR_NUMBER()), N'at ' + @step + N': ' + LEFT(ERROR_MESSAGE(), 400));
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;

SELECT CAST('R|' + id + '|' + result + '|' + REPLACE(REPLACE(REPLACE(detail, N'|', N'/'), CHAR(13), N' '), CHAR(10), N' ') AS nvarchar(4000)) FROM @r
UNION ALL SELECT 'R|TOTAL|' + CONVERT(varchar(10), COUNT(*)) FROM @r;
GO
