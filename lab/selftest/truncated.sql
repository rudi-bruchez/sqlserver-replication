-- Self-test fixture: an nvarchar(max) row, which sqlcmd cuts at 256 characters.
-- Expected: GUARD truncated.
SET NOCOUNT ON;
SELECT CAST(N'R|a|ok|' AS nvarchar(max)) + REPLICATE(CAST(N'x' AS nvarchar(max)), 300);
SELECT 'R|TOTAL|1';
