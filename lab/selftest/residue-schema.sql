-- Self-test fixture: leaves a schema and a type named m_, which sys.objects does
-- not list. Expected: GUARD residue. selftest.sh drops them right after.
SET NOCOUNT ON;
USE Sales;
GO
CREATE SCHEMA m_s;
GO
CREATE TYPE dbo.m_t FROM int;
GO
SET NOCOUNT ON;
SELECT 'R|a|ok|';
SELECT 'R|TOTAL|1';
