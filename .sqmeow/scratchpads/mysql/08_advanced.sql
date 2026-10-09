-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- self-cleaning sqmeow_tmp_adv_* objects. Run statement-by-statement with <CR>.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(total_cents) AS avg_cents, MIN(total_cents) AS min_cents,
       MAX(total_cents) AS max_cents,
       SUM(CASE WHEN total_cents >= 5000 THEN 1 ELSE 0 END) AS big_orders,
       GROUP_CONCAT(DISTINCT status ORDER BY status SEPARATOR '|') AS statuses
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
       CHAR_LENGTH(email) AS email_len, LEFT(name, 4) AS name_prefix,
       RIGHT(email, 12) AS email_suffix,
       SUBSTRING(email, LOCATE('@', email)) AS domain,
       TRIM(name) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       CONCAT(name, ' <', email, '>') AS labeled
FROM sqmeow_customers ORDER BY id LIMIT 5;
SELECT id, name FROM sqmeow_customers WHERE LOWER(name) LIKE '%son' OR email LIKE '%02@%';

-- Numeric functions.
SELECT o.id, o.total_cents, o.total_cents / 100.0 AS dollars,
       ROUND(o.total_cents / 100.0, 2) AS rounded, CEILING(o.total_cents / 100.0) AS ceil_d,
       FLOOR(o.total_cents / 100.0) AS floor_d, MOD(o.total_cents, 1000) AS mod_1k,
       ABS(o.total_cents - 5000) AS dist_5k, POW(i.quantity, 2) AS qty_sq,
       SQRT(i.unit_price_cents) AS price_root
FROM sqmeow_orders o JOIN sqmeow_order_items i ON i.order_id = o.id
ORDER BY o.id LIMIT 5;

-- Date/time functions.
SELECT CURDATE() AS today, NOW() AS now_ts;
SELECT id, ordered_on, DATE_ADD(ordered_on, INTERVAL 7 DAY) AS plus_week,
       YEAR(ordered_on) AS yr, MONTH(ordered_on) AS mo,
       DATE_FORMAT(ordered_on, '%Y-%m') AS ym,
       DAYNAME(ordered_on) AS weekday
FROM sqmeow_orders ORDER BY ordered_on LIMIT 5;
SELECT DATEDIFF(MAX(ordered_on), MIN(ordered_on)) AS span_days FROM sqmeow_orders;

-- CASE + COALESCE + NULLIF + CAST.
SELECT c.id, c.name, c.city, c.active,
       CASE WHEN c.active = 1 THEN 'active' ELSE 'inactive' END AS state,
       CASE c.city WHEN 'Berlin' THEN 'EU' WHEN 'Tokyo' THEN 'APAC' ELSE 'other' END AS region,
       COALESCE(c.note, 'n/a') AS note_or_na,
       NULLIF(c.active, 0) AS active_or_null,
       CAST(o.total_cents AS DECIMAL(10, 2)) / 100 AS dollars
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

-- CTE + recursive CTE (counter doubles as a loop equivalent).
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

-- Join flavors. MySQL has no FULL OUTER JOIN or INTERSECT/EXCEPT:
-- the UNION and NOT EXISTS queries below are the idiomatic equivalents.
SELECT c.name, o.status FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id LIMIT 5;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id LIMIT 8;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id
UNION
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
RIGHT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY 1, 2 LIMIT 8;
SELECT c.name AS customer_without_orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.id IS NULL ORDER BY c.id;
SELECT a.name AS a_name, b.name AS b_name, a.city FROM sqmeow_customers a
JOIN sqmeow_customers b ON b.city = a.city AND b.id > a.id ORDER BY a.city, a.id LIMIT 5;
SELECT s.status, m.method FROM (SELECT DISTINCT status FROM sqmeow_orders) s
CROSS JOIN (SELECT DISTINCT method FROM sqmeow_payments) m ORDER BY s.status, m.method;

-- Set operations: UNION (+ emulated EXCEPT via NOT EXISTS above).
SELECT city FROM sqmeow_customers UNION SELECT category FROM sqmeow_products ORDER BY 1 LIMIT 8;
SELECT city FROM sqmeow_customers UNION ALL SELECT city FROM sqmeow_customers ORDER BY 1 LIMIT 5;
SELECT DISTINCT city FROM sqmeow_customers WHERE active = 1 AND city NOT IN
  (SELECT city FROM sqmeow_customers WHERE active = 0) ORDER BY 1;

-- Grouping extension: WITH ROLLUP.
SELECT COALESCE(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents
FROM sqmeow_orders GROUP BY status WITH ROLLUP ORDER BY status;

-- Session variables.
SET @sqmeow_min = 2000;
SELECT @sqmeow_min AS min_total;
SELECT id, status, total_cents FROM sqmeow_orders WHERE total_cents >= @sqmeow_min ORDER BY id;

-- Temp table lifecycle: insert/update/upsert/delete on a copy, fixtures untouched.
DROP TEMPORARY TABLE IF EXISTS sqmeow_tmp_adv;
CREATE TEMPORARY TABLE sqmeow_tmp_adv (id INT PRIMARY KEY, total_cents INT NOT NULL);
INSERT INTO sqmeow_tmp_adv SELECT id, total_cents FROM sqmeow_orders WHERE status = 'paid';
SELECT COUNT(*) AS copied FROM sqmeow_tmp_adv;
UPDATE sqmeow_tmp_adv SET total_cents = total_cents + 100 WHERE id = 1;
INSERT INTO sqmeow_tmp_adv VALUES (1, 9999) AS new_row ON DUPLICATE KEY UPDATE total_cents = new_row.total_cents;
SELECT id, total_cents FROM sqmeow_tmp_adv WHERE id = 1;
DELETE FROM sqmeow_tmp_adv WHERE total_cents < 2000;
SELECT COUNT(*) AS remaining FROM sqmeow_tmp_adv;
DROP TEMPORARY TABLE IF EXISTS sqmeow_tmp_adv;

-- View lifecycle (MySQL has no TEMPORARY VIEW, so drop guards keep reruns clean).
DROP VIEW IF EXISTS sqmeow_tmp_adv_view;
CREATE VIEW sqmeow_tmp_adv_view AS
SELECT c.city, COUNT(o.id) AS orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id GROUP BY c.city;
SELECT * FROM sqmeow_tmp_adv_view ORDER BY city;
DROP VIEW IF EXISTS sqmeow_tmp_adv_view;

-- Stored procedure with WHILE loop: writes only to a temp table.
DROP PROCEDURE IF EXISTS sqmeow_adv_loop;
CREATE PROCEDURE sqmeow_adv_loop()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE total INT DEFAULT 0;
  DROP TEMPORARY TABLE IF EXISTS sqmeow_tmp_adv_loop;
  CREATE TEMPORARY TABLE sqmeow_tmp_adv_loop (n INT PRIMARY KEY, running INT);
  WHILE i <= 5 DO
    SET total = total + i;
    INSERT INTO sqmeow_tmp_adv_loop VALUES (i, total);
    SET i = i + 1;
  END WHILE;
END;
CALL sqmeow_adv_loop();
SELECT * FROM sqmeow_tmp_adv_loop ORDER BY n;
DROP PROCEDURE IF EXISTS sqmeow_adv_loop;
DROP TEMPORARY TABLE IF EXISTS sqmeow_tmp_adv_loop;

-- Scalar function lifecycle.
DROP FUNCTION IF EXISTS sqmeow_cents_to_dollars;
CREATE FUNCTION sqmeow_cents_to_dollars(cents INT) RETURNS DECIMAL(10, 2)
DETERMINISTIC RETURN cents / 100.0;
SELECT id, total_cents, sqmeow_cents_to_dollars(total_cents) AS dollars
FROM sqmeow_orders ORDER BY id LIMIT 5;
DROP FUNCTION IF EXISTS sqmeow_cents_to_dollars;

-- Query plan for a typical join.
EXPLAIN SELECT c.name, o.total_cents FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.status = 'paid';
