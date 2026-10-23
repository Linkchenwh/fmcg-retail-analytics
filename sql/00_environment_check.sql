-- Environment demonstration only: constants, NOT retail transactions.
-- Expected row count = 3, total = 6. No business conclusion is produced.
SELECT COUNT(*) AS row_count, SUM(value) AS total
FROM (VALUES (1), (2), (3)) AS demo(value);
