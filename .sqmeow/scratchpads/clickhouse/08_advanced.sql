-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update results. Read-only against fixtures except the
-- self-cleaning sqmeow_cents_to_dollars function. Run statement-by-statement
-- with <CR>. ClickHouse has no stored procedures, variables or row-by-row
-- loops: range()/arrayMap cover generation, and mutations are synchronous.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(total_cents) AS avg_cents, MIN(total_cents) AS min_cents,
       MAX(total_cents) AS max_cents,
       SUM(CASE WHEN total_cents >= 5000 THEN 1 ELSE 0 END) AS big_orders,
       COUNTDistinct(customer_id) AS customers
FROM sqmeow_orders
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue_cents DESC;

-- Grouping extension: WITH ROLLUP.
SELECT COALESCE(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents
FROM sqmeow_orders GROUP BY status WITH ROLLUP ORDER BY status;

-- DISTINCT + LIMIT/OFFSET paging + LIMIT BY (one row per group).
SELECT DISTINCT city FROM sqmeow_customers ORDER BY city;
SELECT DISTINCT status FROM sqmeow_orders ORDER BY status;
SELECT id, name, city FROM sqmeow_customers ORDER BY id LIMIT 5 OFFSET 5;
SELECT status, id, total_cents FROM sqmeow_orders ORDER BY status, total_cents DESC LIMIT 2 BY status;

-- String functions.
SELECT id, UPPER(name) AS upper_name, LOWER(city) AS lower_city,
       LENGTH(email) AS email_len, SUBSTRING(name, 1, 4) AS name_prefix,
       SUBSTRING(email, POSITION(email, '@')) AS domain,
       TRIM(name) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       CONCAT(name, ' <', email, '>') AS labeled
FROM sqmeow_customers ORDER BY id LIMIT 5;
SELECT id, name FROM sqmeow_customers WHERE lower(name) LIKE '%son' OR email LIKE '%02@%';

-- Numeric + conditional functions.
SELECT o.id, o.total_cents, o.total_cents / 100.0 AS dollars,
       ROUND(o.total_cents / 100.0, 2) AS rounded, CEIL(o.total_cents / 100.0) AS ceil_d,
       FLOOR(o.total_cents / 100.0) AS floor_d, o.total_cents % 1000 AS mod_1k,
       ABS(o.total_cents - 5000) AS dist_5k, POW(i.quantity, 2) AS qty_sq,
       SQRT(toFloat64(i.unit_price_cents)) AS price_root,
       IF(c.active = 1, 'active', 'inactive') AS state,
       multiIf(c.city = 'Berlin', 'EU', c.city = 'Tokyo', 'APAC', 'other') AS region
FROM sqmeow_orders o
JOIN sqmeow_order_items i ON i.order_id = o.id
JOIN sqmeow_customers c ON c.id = o.customer_id
ORDER BY o.id LIMIT 5;

-- Nullable handling (note is Nullable(String)).
SELECT id, name, IFNULL(note, 'n/a') AS note_or_na, COALESCE(note, 'n/a') AS note_or_na2,
       isNull(note) AS note_is_null
FROM sqmeow_customers ORDER BY id LIMIT 8;

-- Date/time functions.
SELECT today() AS today, NOW() AS now_ts;
SELECT id, ordered_on, dateAdd(ordered_on, INTERVAL 7 DAY) AS plus_week,
       toYear(ordered_on) AS yr, toMonth(ordered_on) AS mo,
       formatDateTime(ordered_on, '%Y-%m') AS ym,
       toStartOfMonth(ordered_on) AS month_start,
       dateDiff('day', MIN(ordered_on) OVER (), ordered_on) AS days_since_first
FROM sqmeow_orders ORDER BY ordered_on LIMIT 5;

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

-- CTE + array generation as the loop equivalent.
WITH city_revenue AS (
  SELECT c.city, SUM(o.total_cents) AS revenue_cents
  FROM sqmeow_customers c JOIN sqmeow_orders o ON o.customer_id = c.id
  GROUP BY c.city
)
SELECT city, revenue_cents FROM city_revenue ORDER BY revenue_cents DESC;
SELECT range(1, 6) AS one_to_five;
SELECT arrayMap(x -> x * x, range(1, 6)) AS squares, arraySum(range(1, 6)) AS sum_1_to_5;

-- Window functions (require a modern ClickHouse server).
SELECT id, status, total_cents,
       ROW_NUMBER() OVER (ORDER BY total_cents DESC) AS rn,
       DENSE_RANK() OVER (PARTITION BY status ORDER BY total_cents DESC) AS status_rank,
       NTILE(4) OVER (ORDER BY total_cents DESC) AS quartile
FROM sqmeow_orders ORDER BY total_cents DESC LIMIT 8;
SELECT id, customer_id, ordered_on, total_cents,
       lagInFrame(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS prev_total,
       leadInFrame(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS next_total,
       SUM(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_cents
FROM sqmeow_orders ORDER BY customer_id, ordered_on;

-- Join flavors + anti-join + PREWHERE on the MergeTree key.
SELECT c.name, o.status FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.name LIMIT 5;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.name, o.id LIMIT 8;
-- Missing right-side keys read as defaults (0), not NULL, under default settings.
SELECT c.name AS customer_without_orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.id = 0 ORDER BY c.name;
SELECT c.name, o.id AS order_id FROM sqmeow_orders o
RIGHT JOIN sqmeow_customers c ON o.customer_id = c.id ORDER BY c.name LIMIT 8;
SELECT id, status, total_cents FROM sqmeow_orders PREWHERE id > 10 ORDER BY id LIMIT 5;

-- Set operations.
SELECT city FROM sqmeow_customers UNION ALL SELECT city FROM sqmeow_customers ORDER BY 1 LIMIT 5;
SELECT DISTINCT city FROM sqmeow_customers WHERE active = 1 AND city NOT IN
  (SELECT city FROM sqmeow_customers WHERE active = 0) ORDER BY 1;

-- Scalar function lifecycle (ClickHouse lambda functions).
DROP FUNCTION IF EXISTS sqmeow_cents_to_dollars;
CREATE FUNCTION sqmeow_cents_to_dollars AS (cents) -> cents / 100.0;
SELECT id, total_cents, sqmeow_cents_to_dollars(total_cents) AS dollars
FROM sqmeow_orders ORDER BY id LIMIT 5;
DROP FUNCTION IF EXISTS sqmeow_cents_to_dollars;

-- Query plan for a typical join.
EXPLAIN SELECT c.name, o.total_cents FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.status = 'paid';
