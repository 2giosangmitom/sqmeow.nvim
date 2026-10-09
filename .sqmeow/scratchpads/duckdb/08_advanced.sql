-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- self-cleaning sqmeow_tmp_adv_* objects. Run statement-by-statement with <CR>.
-- DuckDB has no stored procedures or session variables: macros cover scalar
-- functions, and range()/generate_series cover loop-style row generation.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(total_cents)::bigint AS avg_cents, MIN(total_cents) AS min_cents,
       MAX(total_cents) AS max_cents,
       COUNT(*) FILTER (WHERE total_cents >= 5000) AS big_orders,
       STRING_AGG(DISTINCT status, '|') AS statuses
FROM sqmeow_orders
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue_cents DESC;

-- GROUP BY ALL shorthand + DISTINCT + LIMIT/OFFSET paging.
SELECT city, active, COUNT(*) AS n FROM sqmeow_customers GROUP BY ALL ORDER BY city, active;
SELECT DISTINCT city FROM sqmeow_customers ORDER BY city;
SELECT id, name, city FROM sqmeow_customers ORDER BY id LIMIT 5 OFFSET 5;

-- String functions.
SELECT id, UPPER(name) AS upper_name, LOWER(city) AS lower_city,
       LENGTH(email) AS email_len, LEFT(name, 4) AS name_prefix,
       SUBSTRING(email FROM POSITION('@' IN email)) AS domain,
       TRIM(name) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       CONCAT(name, ' <', email, '>') AS labeled,
       STARTS_WITH(email, 'customer') AS is_customer_mail
FROM sqmeow_customers ORDER BY id LIMIT 5;
SELECT id, name FROM sqmeow_customers WHERE name ILIKE '%son' OR email LIKE '%02@%';

-- Numeric functions.
SELECT o.id, o.total_cents, o.total_cents / 100.0 AS dollars,
       ROUND(o.total_cents / 100.0, 2) AS rounded, CEIL(o.total_cents / 100.0) AS ceil_d,
       FLOOR(o.total_cents / 100.0) AS floor_d, (o.total_cents % 1000) AS mod_1k,
       ABS(o.total_cents - 5000) AS dist_5k, POWER(i.quantity, 2) AS qty_sq,
       SQRT(i.unit_price_cents) AS price_root
FROM sqmeow_orders o JOIN sqmeow_order_items i ON i.order_id = o.id
ORDER BY o.id LIMIT 5;

-- Date/time functions.
SELECT CURRENT_DATE AS today, NOW() AS now_ts;
SELECT id, ordered_on, ordered_on + INTERVAL 7 DAYS AS plus_week,
       YEAR(ordered_on) AS yr, MONTH(ordered_on) AS mo,
       STRFTIME(ordered_on, '%Y-%m') AS ym,
       DATE_TRUNC('month', ordered_on)::date AS month_start,
       DATEDIFF('day', MIN(ordered_on) OVER (), ordered_on) AS days_since_first
FROM sqmeow_orders ORDER BY ordered_on LIMIT 5;

-- CASE + COALESCE + NULLIF + CAST.
SELECT c.id, c.name, c.city, c.active,
       CASE WHEN c.active = 1 THEN 'active' ELSE 'inactive' END AS state,
       CASE c.city WHEN 'Berlin' THEN 'EU' WHEN 'Tokyo' THEN 'APAC' ELSE 'other' END AS region,
       COALESCE(c.note, 'n/a') AS note_or_na,
       NULLIF(c.active, 0) AS active_or_null,
       CAST(o.total_cents AS numeric) / 100 AS dollars
FROM sqmeow_customers c LEFT JOIN sqmeow_orders o ON o.customer_id = c.id
ORDER BY c.id LIMIT 8;

-- Subqueries: IN, EXISTS, scalar, derived table.
SELECT id, name FROM sqmeow_customers
WHERE id IN (SELECT customer_id FROM sqmeow_orders WHERE status = 'shipped')
ORDER BY id;
SELECT id, name FROM sqmeow_customers c
WHERE EXISTS (SELECT 1 FROM sqmeow_orders o WHERE o.customer_id = c.id AND o.total_cents > 8000)
ORDER BY id;
SELECT id, total_cents FROM sqmeow_orders
WHERE total_cents > (SELECT AVG(total_cents) FROM sqmeow_orders)
ORDER BY total_cents DESC;
SELECT * FROM (SELECT status, COUNT(*) AS n FROM sqmeow_orders GROUP BY status) s
WHERE n >= 4 ORDER BY n DESC;

-- CTE + recursive CTE + row generation as the loop equivalent.
WITH city_revenue AS (
  SELECT c.city, SUM(o.total_cents) AS revenue_cents
  FROM sqmeow_customers c JOIN sqmeow_orders o ON o.customer_id = c.id
  GROUP BY c.city
)
SELECT city, revenue_cents FROM city_revenue ORDER BY revenue_cents DESC;
WITH RECURSIVE counter(n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM counter WHERE n < 5
)
SELECT n, n * n AS square FROM counter;
SELECT UNNEST(RANGE(1, 6)) AS n;
SELECT * FROM (VALUES (1, 'one'), (2, 'two')) t(n, word);

-- Window functions: ranking, offsets, running totals, buckets, QUALIFY.
SELECT id, status, total_cents,
       ROW_NUMBER() OVER (ORDER BY total_cents DESC) AS rn,
       RANK() OVER (ORDER BY total_cents DESC) AS rnk,
       DENSE_RANK() OVER (PARTITION BY status ORDER BY total_cents DESC) AS status_rank,
       NTILE(4) OVER (ORDER BY total_cents DESC) AS quartile
FROM sqmeow_orders ORDER BY total_cents DESC LIMIT 8;
SELECT id, customer_id, ordered_on, total_cents,
       LAG(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS prev_total,
       LEAD(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS next_total,
       FIRST_VALUE(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS first_total
FROM sqmeow_orders ORDER BY customer_id, ordered_on;
SELECT customer_id, ordered_on, total_cents,
       SUM(total_cents) OVER w AS running_cents,
       COUNT(*) OVER w AS running_orders
FROM sqmeow_orders
WINDOW w AS (PARTITION BY customer_id ORDER BY ordered_on ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
ORDER BY customer_id, ordered_on;
SELECT status, total_cents FROM sqmeow_orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY status ORDER BY total_cents DESC) <= 2
ORDER BY status, total_cents DESC;

-- Join flavors: inner/left/right/full/cross/self + anti-join.
SELECT c.name, o.status FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id LIMIT 5;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id LIMIT 8;
SELECT c.name, o.id AS order_id FROM sqmeow_orders o
RIGHT JOIN sqmeow_customers c ON o.customer_id = c.id ORDER BY c.id, o.id LIMIT 8;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
FULL OUTER JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id LIMIT 8;
SELECT c.name AS customer_without_orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.id IS NULL ORDER BY c.id;
SELECT a.name AS a_name, b.name AS b_name, a.city FROM sqmeow_customers a
JOIN sqmeow_customers b ON b.city = a.city AND b.id > a.id ORDER BY a.city, a.id LIMIT 5;
SELECT s.status, m.method FROM (SELECT DISTINCT status FROM sqmeow_orders) s
CROSS JOIN (SELECT DISTINCT method FROM sqmeow_payments) m ORDER BY s.status, m.method;

-- Set operations.
SELECT city FROM sqmeow_customers UNION SELECT category FROM sqmeow_products ORDER BY 1 LIMIT 8;
SELECT city FROM sqmeow_customers UNION ALL SELECT city FROM sqmeow_customers ORDER BY 1 LIMIT 5;
SELECT city FROM sqmeow_customers WHERE active = 1
INTERSECT
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;
SELECT city FROM sqmeow_customers
EXCEPT
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;

-- PIVOT: order counts per customer by status.
PIVOT sqmeow_orders ON status USING COUNT(*) GROUP BY customer_id ORDER BY customer_id LIMIT 5;

-- Grouping extensions: ROLLUP + GROUPING + GROUPING SETS.
SELECT COALESCE(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       GROUPING(status) AS is_total
FROM sqmeow_orders GROUP BY ROLLUP (status) ORDER BY status;
SELECT status, COUNT(*) AS n FROM sqmeow_orders
GROUP BY GROUPING SETS ((status), ()) ORDER BY status;

-- Structs and lists.
SELECT {'city': city, 'orders': COUNT(*)} AS city_struct FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id GROUP BY city ORDER BY city;
SELECT LIST_VALUE(1, 2, 3) AS trio, LEN(LIST_VALUE(1, 2, 3)) AS trio_len;

-- Temp table lifecycle: insert/update/upsert/delete on a copy, fixtures untouched.
DROP TABLE IF EXISTS sqmeow_tmp_adv;
CREATE TEMP TABLE sqmeow_tmp_adv (id INTEGER PRIMARY KEY, total_cents INTEGER NOT NULL);
INSERT INTO sqmeow_tmp_adv SELECT id, total_cents FROM sqmeow_orders WHERE status = 'paid';
SELECT COUNT(*) AS copied FROM sqmeow_tmp_adv;
UPDATE sqmeow_tmp_adv SET total_cents = total_cents + 100 WHERE id = 1;
INSERT INTO sqmeow_tmp_adv VALUES (1, 9999) ON CONFLICT (id) DO UPDATE SET total_cents = EXCLUDED.total_cents;
SELECT id, total_cents FROM sqmeow_tmp_adv WHERE id = 1;
DELETE FROM sqmeow_tmp_adv WHERE total_cents < 2000;
SELECT COUNT(*) AS remaining FROM sqmeow_tmp_adv;
DROP TABLE IF EXISTS sqmeow_tmp_adv;

-- Temp view lifecycle.
CREATE OR REPLACE TEMP VIEW sqmeow_tmp_adv_view AS
SELECT c.city, COUNT(o.id) AS orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id GROUP BY c.city;
SELECT * FROM sqmeow_tmp_adv_view ORDER BY city;
DROP VIEW IF EXISTS sqmeow_tmp_adv_view;

-- Macro lifecycle (DuckDB scalar functions).
CREATE OR REPLACE MACRO sqmeow_cents_to_dollars(cents) AS cents / 100.0;
SELECT id, total_cents, sqmeow_cents_to_dollars(total_cents) AS dollars
FROM sqmeow_orders ORDER BY id LIMIT 5;
DROP MACRO IF EXISTS sqmeow_cents_to_dollars;

-- Query plan for a typical join.
EXPLAIN SELECT c.name, o.total_cents FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.status = 'paid';
