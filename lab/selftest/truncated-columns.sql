-- Self-test fixture: a row printed as separate columns, one of them nvarchar(max):
-- sqlcmd cuts that field at 256 characters and the line is longer than 256.
-- Expected: GUARD truncated.
SET NOCOUNT ON;
SELECT 'R', 'a', 'ok', CONCAT(REPLICATE(CAST('x' AS nvarchar(max)), 300), 'END');
SELECT 'R|TOTAL|1';
