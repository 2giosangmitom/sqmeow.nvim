-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- self-cleaning sqmeow_tmp_adv_* objects. Run statement-by-statement with <CR>.
-- SQLite has no stored procedures, functions, variables or loops: CTEs stand in
-- for variables, a recursive CTE for loops, and a TEMP TRIGGER covers triggers.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(total_cents) AS avg_cents, MIN(total_cents) AS min_cents,
       MAX(total_cents) AS max_cents,
       SUM(CASE WHEN total_cents >= 5000 THEN 1 ELSE 0 END) AS big_orders,
       GROUP_CONCAT(DISTINCT status) AS statuses
FROM sqmeow_orders
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue_cents DESC;

-- DISTINCT + LIMIT/OFFSET paging.
SELECT DISTINCT city FROM sqmeow_customers ORDER BY city;
SELECT DISTINCT status FROM sqmeow_orders ORDER BY status;
SELECT id, name, city FROM sqmeow_customers ORDER BY id LIMIT 5 OFFSET 5;

-- String functions.
SELECT id, UPPER(name) AS upper_name, LOWER(city) AS lower_city,
       LENGTH(email) AS email_len, SUBSTR(name, 1, 4) AS name_prefix,
       SUBSTR(email, INSTR(email, '@')) AS domain,
       TRIM(name) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       name || ' <' || email || '>' AS labeled,
       PRINTF('order-%03d', id) AS padded
FROM sqmeow_customers ORDER BY id LIMIT 5;
SELECT id, name FROM sqmeow_customers WHERE name LIKE '%son' COLLATE NOCASE OR email LIKE '%02@%';

-- Numeric functions.
SELECT o.id, o.total_cents, o.total_cents / 100.0 AS dollars,
       ROUND(o.total_cents / 100.0, 2) AS rounded,
       CAST(o.total_cents / 100 AS INTEGER) AS floor_d,
       ABS(o.total_cents - 5000) AS dist_5k, (i.quantity * i.quantity) AS qty_sq,
       (o.total_cents % 1000) AS mod_1k
FROM sqmeow_orders o JOIN sqmeow_order_items i ON i.order_id = o.id
ORDER BY o.id LIMIT 5;

-- Date/time functions (SQLite stores these fixtures as TEXT).
SELECT DATE('now') AS today, DATETIME('now') AS now_ts;
SELECT id, ordered_on, DATE(ordered_on, '+7 days') AS plus_week,
       SUBSTR(ordered_on, 1, 7) AS ym,
       STRFTIME('%Y', ordered_on) AS yr, STRFTIME('%m', ordered_on) AS mo,
       STRFTIME('%w', ordered_on) AS weekday
FROM sqmeow_orders ORDER BY ordered_on LIMIT 5;
SELECT JULIANDAY(MAX(ordered_on)) - JULIANDAY(MIN(ordered_on)) AS span_days FROM sqmeow_orders;

-- CASE + COALESCE + NULLIF + CAST.
SELECT c.id, c.name, c.city, c.active,
       CASE WHEN c.active = 1 THEN 'active' ELSE 'inactive' END AS state,
       CASE c.city WHEN 'Berlin' THEN 'EU' WHEN 'Tokyo' THEN 'APAC' ELSE 'other' END AS region,
       COALESCE(c.note, 'n/a') AS note_or_na,
       NULLIF(c.active, 0) AS active_or_null,
       CAST(o.total_cents AS REAL) / 100 AS dollars
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
SELECT id, name FROM sqmeow_customers c WHERE NOT EXISTS
  (SELECT 1 FROM sqmeow_orders o WHERE o.customer_id = c.id) ORDER BY id;

-- CTEs as named variables + recursive CTE as the loop equivalent.
WITH vars AS (SELECT 2000 AS min_total, 'paid' AS wanted_status)
SELECT o.id, o.status, o.total_cents FROM sqmeow_orders o, vars v
WHERE o.total_cents >= v.min_total AND o.status = v.wanted_status ORDER BY o.id;
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

-- Window functions: ranking, offsets, running totals, buckets.
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
       SUM(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_cents,
       COUNT(*) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_orders
FROM sqmeow_orders ORDER BY customer_id, ordered_on;

-- Join flavors. SQLite has no RIGHT/FULL OUTER JOIN: the UNION queries below
-- are the idiomatic equivalents.
SELECT c.name, o.status FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id LIMIT 5;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id LIMIT 8;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id
UNION
SELECT c.name, o.id AS order_id FROM sqmeow_orders o
LEFT JOIN sqmeow_customers c ON o.customer_id = c.id ORDER BY 1, 2 LIMIT 8;
SELECT c.name AS customer_without_orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.id IS NULL ORDER BY c.id;
SELECT a.name AS a_name, b.name AS b_name, a.city FROM sqmeow_customers a
JOIN sqmeow_customers b ON b.city = a.city AND b.id > a.id ORDER BY a.city, a.id LIMIT 5;
SELECT s.status, m.method FROM (SELECT DISTINCT status FROM sqmeow_orders) s
CROSS JOIN (SELECT DISTINCT method FROM sqmeow_payments) m ORDER BY s.status, m.method;

-- Set operations (SQLite supports all three) + emulated ROLLUP via UNION ALL.
SELECT city FROM sqmeow_customers UNION SELECT category FROM sqmeow_products ORDER BY 1 LIMIT 8;
SELECT city FROM sqmeow_customers UNION ALL SELECT city FROM sqmeow_customers ORDER BY 1 LIMIT 5;
SELECT city FROM sqmeow_customers WHERE active = 1
INTERSECT
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;
SELECT city FROM sqmeow_customers
EXCEPT
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;
SELECT COALESCE(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents
FROM sqmeow_orders GROUP BY status
UNION ALL
SELECT 'ALL' AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents FROM sqmeow_orders
ORDER BY 1;

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
CREATE TEMP VIEW IF NOT EXISTS sqmeow_tmp_adv_view AS
SELECT c.city, COUNT(o.id) AS orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id GROUP BY c.city;
SELECT * FROM sqmeow_tmp_adv_view ORDER BY city;
DROP VIEW IF EXISTS sqmeow_tmp_adv_view;

-- Trigger lifecycle: an AFTER INSERT trigger logs into a second temp table.
DROP TABLE IF EXISTS sqmeow_tmp_adv;
DROP TABLE IF EXISTS sqmeow_tmp_adv_log;
CREATE TEMP TABLE sqmeow_tmp_adv (id INTEGER PRIMARY KEY, total_cents INTEGER NOT NULL);
CREATE TEMP TABLE sqmeow_tmp_adv_log (order_id INTEGER NOT NULL);
DROP TRIGGER IF EXISTS sqmeow_adv_trg;
CREATE TEMP TRIGGER sqmeow_adv_trg AFTER INSERT ON sqmeow_tmp_adv
BEGIN
  INSERT INTO sqmeow_tmp_adv_log VALUES (NEW.id);
END;
INSERT INTO sqmeow_tmp_adv VALUES (9001, 1234), (9002, 5678);
SELECT * FROM sqmeow_tmp_adv_log ORDER BY order_id;
DROP TRIGGER IF EXISTS sqmeow_adv_trg;
DROP TABLE IF EXISTS sqmeow_tmp_adv;
DROP TABLE IF EXISTS sqmeow_tmp_adv_log;

-- Query plan for a typical join.
EXPLAIN QUERY PLAN SELECT c.name, o.total_cents FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.status = 'paid';
