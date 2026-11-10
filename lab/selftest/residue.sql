-- Self-test fixture: leaves a table named m_ behind. Expected: GUARD residue.
-- selftest.sh drops it right after.
SET NOCOUNT ON;
CREATE TABLE Sales.dbo.m_left (id int);
SELECT 'R|a|ok|';
SELECT 'R|TOTAL|1';
