-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- self-cleaning dbo.sqmeow_tmp_adv objects. Batches are separated by GO;
-- run one batch at a time with <CR>. Variables live only within their batch.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(CAST(total_cents AS float)) AS avg_cents,
       MIN(total_cents) AS min_cents, MAX(total_cents) AS max_cents,
       SUM(CASE WHEN total_cents >= 5000 THEN 1 ELSE 0 END) AS big_orders
FROM dbo.sqmeow_orders
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue_cents DESC;
GO

-- DISTINCT + TOP + OFFSET/FETCH paging.
SELECT DISTINCT city FROM dbo.sqmeow_customers ORDER BY city;
GO
SELECT DISTINCT status FROM dbo.sqmeow_orders ORDER BY status;
GO
SELECT TOP 5 id, name, city FROM dbo.sqmeow_customers ORDER BY id;
GO
SELECT id, name, city FROM dbo.sqmeow_customers ORDER BY id OFFSET 5 ROWS FETCH NEXT 5 ROWS ONLY;
GO

-- String functions.
SELECT TOP 5 id, UPPER(name) AS upper_name, LOWER(city) AS lower_city,
       LEN(email) AS email_len, LEFT(name, 4) AS name_prefix,
       RIGHT(email, 12) AS email_suffix,
       SUBSTRING(email, CHARINDEX('@', email), 99) AS domain,
       LTRIM(RTRIM(name)) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       CONCAT(name, N' <', email, N'>') AS labeled
FROM dbo.sqmeow_customers ORDER BY id;
GO
SELECT id, name FROM dbo.sqmeow_customers WHERE name LIKE N'%son' OR email LIKE N'%02@%';
GO

-- Numeric functions.
SELECT TOP 5 o.id, o.total_cents, o.total_cents / 100.0 AS dollars,
       ROUND(o.total_cents / 100.0, 2) AS rounded, CEILING(o.total_cents / 100.0) AS ceil_d,
       FLOOR(o.total_cents / 100.0) AS floor_d, ABS(o.total_cents - 5000) AS dist_5k,
       POWER(i.quantity, 2) AS qty_sq, SQRT(CAST(i.unit_price_cents AS float)) AS price_root
FROM dbo.sqmeow_orders o JOIN dbo.sqmeow_order_items i ON i.order_id = o.id
ORDER BY o.id;
GO

-- Date/time functions.
SELECT GETDATE() AS now_ts, CAST(GETDATE() AS date) AS today;
GO
SELECT TOP 5 id, ordered_on, DATEADD(day, 7, ordered_on) AS plus_week,
       YEAR(ordered_on) AS yr, MONTH(ordered_on) AS mo,
       FORMAT(ordered_on, 'yyyy-MM') AS ym, DATENAME(weekday, ordered_on) AS weekday,
       EOMONTH(ordered_on) AS month_end
FROM dbo.sqmeow_orders ORDER BY ordered_on;
GO
SELECT DATEDIFF(day, MIN(ordered_on), MAX(ordered_on)) AS span_days FROM dbo.sqmeow_orders;
GO

-- CASE + COALESCE/ISNULL + NULLIF + CAST/TRY_CAST.
SELECT TOP 8 c.id, c.name, c.city, c.active,
       CASE WHEN c.active = 1 THEN 'active' ELSE 'inactive' END AS state,
       CASE c.city WHEN N'Berlin' THEN N'EU' WHEN N'Tokyo' THEN N'APAC' ELSE N'other' END AS region,
       COALESCE(c.note, N'n/a') AS note_or_na, ISNULL(c.note, N'n/a') AS note_or_na2,
       NULLIF(c.active, 0) AS active_or_null,
       CAST(o.total_cents AS decimal(10, 2)) / 100 AS dollars,
       TRY_CAST(c.note AS int) AS note_as_int
FROM dbo.sqmeow_customers c LEFT JOIN dbo.sqmeow_orders o ON o.customer_id = c.id
ORDER BY c.id;
GO

-- Subqueries: IN, EXISTS, scalar, derived table.
SELECT id, name FROM dbo.sqmeow_customers
WHERE id IN (SELECT customer_id FROM dbo.sqmeow_orders WHERE status = 'shipped')
ORDER BY id;
GO
SELECT id, name FROM dbo.sqmeow_customers c
WHERE EXISTS (SELECT 1 FROM dbo.sqmeow_orders o WHERE o.customer_id = c.id AND o.total_cents > 8000)
ORDER BY id;
GO
SELECT id, total_cents FROM dbo.sqmeow_orders
WHERE total_cents > (SELECT AVG(CAST(total_cents AS float)) FROM dbo.sqmeow_orders)
ORDER BY total_cents DESC;
GO
SELECT * FROM (SELECT status, COUNT(*) AS n FROM dbo.sqmeow_orders GROUP BY status) s
WHERE n >= 4 ORDER BY n DESC;
GO

-- CTE + recursive CTE (counter doubles as a loop equivalent).
WITH city_revenue AS (
  SELECT c.city, SUM(o.total_cents) AS revenue_cents
  FROM dbo.sqmeow_customers c JOIN dbo.sqmeow_orders o ON o.customer_id = c.id
  GROUP BY c.city
)
SELECT city, revenue_cents FROM city_revenue ORDER BY revenue_cents DESC;
GO
WITH counter AS (
  SELECT 1 AS n
  UNION ALL
  SELECT n + 1 FROM counter WHERE n < 5
)
SELECT n, n * n AS square FROM counter;
GO

-- Window functions: ranking, offsets, running totals, buckets, first/last.
SELECT TOP 8 id, status, total_cents,
       ROW_NUMBER() OVER (ORDER BY total_cents DESC) AS rn,
       RANK() OVER (ORDER BY total_cents DESC) AS rnk,
       DENSE_RANK() OVER (PARTITION BY status ORDER BY total_cents DESC) AS status_rank,
       NTILE(4) OVER (ORDER BY total_cents DESC) AS quartile
FROM dbo.sqmeow_orders ORDER BY total_cents DESC;
GO
SELECT id, customer_id, ordered_on, total_cents,
       LAG(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS prev_total,
       LEAD(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS next_total,
       FIRST_VALUE(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS first_total,
       LAST_VALUE(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_total
FROM dbo.sqmeow_orders ORDER BY customer_id, ordered_on;
GO
SELECT customer_id, ordered_on, total_cents,
       SUM(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_cents,
       COUNT(*) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_orders
FROM dbo.sqmeow_orders ORDER BY customer_id, ordered_on;
GO

-- Join flavors: inner/left/right/full/cross/self + anti-join.
SELECT TOP 5 c.name, o.status FROM dbo.sqmeow_customers c
JOIN dbo.sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id;
GO
SELECT TOP 8 c.name, o.id AS order_id FROM dbo.sqmeow_customers c
LEFT JOIN dbo.sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id;
GO
SELECT TOP 8 c.name, o.id AS order_id FROM dbo.sqmeow_orders o
RIGHT JOIN dbo.sqmeow_customers c ON o.customer_id = c.id ORDER BY c.id, o.id;
GO
SELECT TOP 8 c.name, o.id AS order_id FROM dbo.sqmeow_customers c
FULL OUTER JOIN dbo.sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id;
GO
SELECT c.name AS customer_without_orders FROM dbo.sqmeow_customers c
LEFT JOIN dbo.sqmeow_orders o ON o.customer_id = c.id WHERE o.id IS NULL ORDER BY c.id;
GO
SELECT TOP 5 a.name AS a_name, b.name AS b_name, a.city FROM dbo.sqmeow_customers a
JOIN dbo.sqmeow_customers b ON b.city = a.city AND b.id > a.id ORDER BY a.city, a.id;
GO
SELECT s.status, m.method FROM (SELECT DISTINCT status FROM dbo.sqmeow_orders) s
CROSS JOIN (SELECT DISTINCT method FROM dbo.sqmeow_payments) m ORDER BY s.status, m.method;
GO

-- APPLY: TOP 1 latest order per customer (T-SQL alternative to lateral joins).
SELECT c.name, o.id AS latest_order_id, o.total_cents
FROM dbo.sqmeow_customers c
OUTER APPLY (SELECT TOP 1 id, total_cents FROM dbo.sqmeow_orders
             WHERE customer_id = c.id ORDER BY ordered_on DESC) o
ORDER BY c.id;
GO

-- Set operations.
SELECT city FROM dbo.sqmeow_customers UNION SELECT category FROM dbo.sqmeow_products ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 8 ROWS ONLY;
GO
SELECT city FROM dbo.sqmeow_customers UNION ALL SELECT city FROM dbo.sqmeow_customers ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY;
GO
SELECT city FROM dbo.sqmeow_customers WHERE active = 1
INTERSECT
SELECT city FROM dbo.sqmeow_customers WHERE active = 0 ORDER BY 1;
GO
SELECT city FROM dbo.sqmeow_customers
EXCEPT
SELECT city FROM dbo.sqmeow_customers WHERE active = 0 ORDER BY 1;
GO

-- PIVOT: order counts per status.
SELECT [paid], [shipped], [cancelled], [new]
FROM (SELECT status, id FROM dbo.sqmeow_orders) AS src
PIVOT (COUNT(id) FOR status IN ([paid], [shipped], [cancelled], [new])) AS p;
GO

-- Grouping extensions: ROLLUP + CUBE + GROUPING SETS.
SELECT COALESCE(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       GROUPING(status) AS is_total
FROM dbo.sqmeow_orders GROUP BY ROLLUP (status) ORDER BY status;
GO
SELECT status, COUNT(*) AS n FROM dbo.sqmeow_orders
GROUP BY CUBE (status) ORDER BY status;
GO

-- STRING_AGG: order ids per status.
SELECT status, STRING_AGG(CAST(id AS NVARCHAR(12)), N',') WITHIN GROUP (ORDER BY id) AS order_ids
FROM dbo.sqmeow_orders GROUP BY status ORDER BY status;
GO

-- Variables + WHILE loop + IF/ELSE in one batch.
DECLARE @min_total INT = 2000, @i INT = 1, @running INT = 0;
SELECT @min_total AS min_total;
SELECT id, status, total_cents FROM dbo.sqmeow_orders WHERE total_cents >= @min_total ORDER BY id;
WHILE @i <= 5 BEGIN SET @running += @i; SET @i += 1; END;
SELECT @running AS sum_1_to_5;
IF @running = 15 SELECT 'loop ok' AS check_result; ELSE SELECT 'loop broken' AS check_result;
GO

-- TRY/CATCH.
BEGIN TRY
  SELECT 1 / 0 AS boom;
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS err_no, ERROR_MESSAGE() AS err_msg;
END CATCH;
GO

-- Temp copy lifecycle with MERGE; fixtures untouched.
DROP TABLE IF EXISTS dbo.sqmeow_tmp_adv;
CREATE TABLE dbo.sqmeow_tmp_adv (id INT PRIMARY KEY, total_cents INT NOT NULL);
INSERT INTO dbo.sqmeow_tmp_adv SELECT id, total_cents FROM dbo.sqmeow_orders WHERE status = 'paid';
MERGE dbo.sqmeow_tmp_adv AS t
USING (SELECT id, total_cents FROM dbo.sqmeow_orders WHERE status = 'shipped') AS s ON t.id = s.id
WHEN MATCHED THEN UPDATE SET t.total_cents = s.total_cents
WHEN NOT MATCHED THEN INSERT (id, total_cents) VALUES (s.id, s.total_cents);
SELECT COUNT(*) AS merged FROM dbo.sqmeow_tmp_adv;
DROP TABLE IF EXISTS dbo.sqmeow_tmp_adv;
GO

-- Transaction with ROLLBACK leaves fixtures unchanged.
DROP TABLE IF EXISTS dbo.sqmeow_tmp_adv;
CREATE TABLE dbo.sqmeow_tmp_adv (id INT PRIMARY KEY, total_cents INT NOT NULL);
BEGIN TRAN;
INSERT INTO dbo.sqmeow_tmp_adv VALUES (9001, 1234);
ROLLBACK;
SELECT COUNT(*) AS rolled_back FROM dbo.sqmeow_tmp_adv;
DROP TABLE IF EXISTS dbo.sqmeow_tmp_adv;
GO

-- Stored procedure lifecycle.
DROP PROCEDURE IF EXISTS dbo.sqmeow_adv_seed;
DROP FUNCTION IF EXISTS dbo.sqmeow_cents_to_dollars;
GO
CREATE PROCEDURE dbo.sqmeow_adv_seed AS
BEGIN
  SET NOCOUNT ON;
  SELECT COUNT(*) AS customer_count FROM dbo.sqmeow_customers;
END;
GO
EXEC dbo.sqmeow_adv_seed;
GO
CREATE FUNCTION dbo.sqmeow_cents_to_dollars(@cents INT) RETURNS DECIMAL(10, 2) AS
BEGIN
  RETURN @cents / 100.0;
END;
GO
SELECT TOP 5 id, total_cents, dbo.sqmeow_cents_to_dollars(total_cents) AS dollars
FROM dbo.sqmeow_orders ORDER BY id;
GO
DROP FUNCTION IF EXISTS dbo.sqmeow_cents_to_dollars;
DROP PROCEDURE IF EXISTS dbo.sqmeow_adv_seed;
GO
