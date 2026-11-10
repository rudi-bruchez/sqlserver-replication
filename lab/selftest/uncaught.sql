-- Self-test fixture: an SQL error reaches the output. Expected: GUARD uncaught.
SET NOCOUNT ON;
SELECT m_no_such_column FROM sys.databases;
GO
SET NOCOUNT ON;
SELECT 'R|a|ok|';
SELECT 'R|TOTAL|1';
