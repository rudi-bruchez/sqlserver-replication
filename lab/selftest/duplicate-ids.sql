-- Self-test fixture: the same case id twice, TOTAL consistent. Expected: GUARD total.
SET NOCOUNT ON;
SELECT 'R|a|ok|';
SELECT 'R|a|1205|';
SELECT 'R|TOTAL|2';
