-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- self-cleaning sqmeow_tmp_adv* objects. Run statement-by-statement with <CR>.

-- Aggregation: GROUP BY + HAVING.
SELECT status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       AVG(total_cents) AS avg_cents, MIN(total_cents) AS min_cents,
       MAX(total_cents) AS max_cents,
       SUM(CASE WHEN total_cents >= 5000 THEN 1 ELSE 0 END) AS big_orders
FROM sqmeow_orders
GROUP BY status
HAVING COUNT(*) > 1
ORDER BY revenue_cents DESC;

-- DISTINCT + FETCH FIRST paging (Oracle 12c+).
SELECT DISTINCT city FROM sqmeow_customers ORDER BY city;
SELECT DISTINCT status FROM sqmeow_orders ORDER BY status;
SELECT id, name, city FROM sqmeow_customers ORDER BY id FETCH FIRST 5 ROWS ONLY;
SELECT id, name, city FROM sqmeow_customers ORDER BY id OFFSET 5 ROWS FETCH NEXT 5 ROWS ONLY;

-- String functions (|| concat, SUBSTR/INSTR, LIKE).
SELECT id, UPPER(name) AS upper_name, LOWER(city) AS lower_city,
       LENGTH(email) AS email_len, SUBSTR(name, 1, 4) AS name_prefix,
       SUBSTR(email, INSTR(email, '@')) AS domain,
       TRIM(name) AS trimmed, REPLACE(city, 'a', '@') AS city_masked,
       name || ' <' || email || '>' AS labeled
FROM sqmeow_customers ORDER BY id FETCH FIRST 5 ROWS ONLY;
SELECT id, name FROM sqmeow_customers WHERE LOWER(name) LIKE '%son' OR email LIKE '%02@%';

-- Numeric functions.
SELECT o.id, o.total_cents, o.total_cents / 100 AS dollars,
       ROUND(o.total_cents / 100, 2) AS rounded, CEIL(o.total_cents / 100) AS ceil_d,
       FLOOR(o.total_cents / 100) AS floor_d, MOD(o.total_cents, 1000) AS mod_1k,
       ABS(o.total_cents - 5000) AS dist_5k, POWER(i.quantity, 2) AS qty_sq,
       SQRT(i.unit_price_cents) AS price_root
FROM sqmeow_orders o JOIN sqmeow_order_items i ON i.order_id = o.id
ORDER BY o.id FETCH FIRST 5 ROWS ONLY;

-- Date/time functions.
SELECT SYSDATE AS now_ts FROM dual;
SELECT id, ordered_on, ordered_on + 7 AS plus_week,
       ADD_MONTHS(ordered_on, 1) AS plus_month,
       EXTRACT(YEAR FROM ordered_on) AS yr, EXTRACT(MONTH FROM ordered_on) AS mo,
       TO_CHAR(ordered_on, 'YYYY-MM') AS ym,
       TO_CHAR(ordered_on, 'Day') AS weekday
FROM sqmeow_orders ORDER BY ordered_on FETCH FIRST 5 ROWS ONLY;
SELECT MONTHS_BETWEEN(MAX(ordered_on), MIN(ordered_on)) AS span_months FROM sqmeow_orders;

-- CASE + NVL/COALESCE + NULLIF + CAST.
SELECT c.id, c.name, c.city, c.active,
       CASE WHEN c.active = 1 THEN 'active' ELSE 'inactive' END AS state,
       CASE c.city WHEN 'Berlin' THEN 'EU' WHEN 'Tokyo' THEN 'APAC' ELSE 'other' END AS region,
       NVL(c.note, 'n/a') AS note_or_na, COALESCE(c.note, 'n/a') AS note_or_na2,
       NULLIF(c.active, 0) AS active_or_null,
       CAST(o.total_cents AS NUMBER(10, 2)) / 100 AS dollars
FROM sqmeow_customers c LEFT JOIN sqmeow_orders o ON o.customer_id = c.id
ORDER BY c.id FETCH FIRST 8 ROWS ONLY;

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

-- CTE + hierarchical query (CONNECT BY doubles as a loop equivalent).
WITH city_revenue AS (
  SELECT c.city, SUM(o.total_cents) AS revenue_cents
  FROM sqmeow_customers c JOIN sqmeow_orders o ON o.customer_id = c.id
  GROUP BY c.city
)
SELECT city, revenue_cents FROM city_revenue ORDER BY revenue_cents DESC;
SELECT LEVEL AS n, LEVEL * LEVEL AS square FROM dual CONNECT BY LEVEL <= 5;

-- Window functions: ranking, offsets, running totals, buckets, first/last.
SELECT id, status, total_cents,
       ROW_NUMBER() OVER (ORDER BY total_cents DESC) AS rn,
       RANK() OVER (ORDER BY total_cents DESC) AS rnk,
       DENSE_RANK() OVER (PARTITION BY status ORDER BY total_cents DESC) AS status_rank,
       NTILE(4) OVER (ORDER BY total_cents DESC) AS quartile
FROM sqmeow_orders ORDER BY total_cents DESC FETCH FIRST 8 ROWS ONLY;
SELECT id, customer_id, ordered_on, total_cents,
       LAG(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS prev_total,
       LEAD(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS next_total,
       FIRST_VALUE(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on) AS first_total,
       LAST_VALUE(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_total
FROM sqmeow_orders ORDER BY customer_id, ordered_on;
SELECT customer_id, ordered_on, total_cents,
       SUM(total_cents) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_cents,
       COUNT(*) OVER (PARTITION BY customer_id ORDER BY ordered_on
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_orders
FROM sqmeow_orders ORDER BY customer_id, ordered_on;

-- Join flavors: inner/left/right/full/cross/self + anti-join.
SELECT c.name, o.status FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id FETCH FIRST 5 ROWS ONLY;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id FETCH FIRST 8 ROWS ONLY;
SELECT c.name, o.id AS order_id FROM sqmeow_orders o
RIGHT JOIN sqmeow_customers c ON o.customer_id = c.id ORDER BY c.id, o.id FETCH FIRST 8 ROWS ONLY;
SELECT c.name, o.id AS order_id FROM sqmeow_customers c
FULL OUTER JOIN sqmeow_orders o ON o.customer_id = c.id ORDER BY c.id, o.id FETCH FIRST 8 ROWS ONLY;
SELECT c.name AS customer_without_orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.id IS NULL ORDER BY c.id;
SELECT a.name AS a_name, b.name AS b_name, a.city FROM sqmeow_customers a
JOIN sqmeow_customers b ON b.city = a.city AND b.id > a.id ORDER BY a.city, a.id FETCH FIRST 5 ROWS ONLY;
SELECT s.status, m.method FROM (SELECT DISTINCT status FROM sqmeow_orders) s
CROSS JOIN (SELECT DISTINCT method FROM sqmeow_payments) m ORDER BY s.status, m.method;

-- Set operations. Oracle spells EXCEPT as MINUS.
SELECT city FROM sqmeow_customers UNION SELECT category FROM sqmeow_products ORDER BY 1 FETCH FIRST 8 ROWS ONLY;
SELECT city FROM sqmeow_customers UNION ALL SELECT city FROM sqmeow_customers ORDER BY 1 FETCH FIRST 5 ROWS ONLY;
SELECT city FROM sqmeow_customers WHERE active = 1
INTERSECT
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;
SELECT city FROM sqmeow_customers
MINUS
SELECT city FROM sqmeow_customers WHERE active = 0 ORDER BY 1;

-- LISTAGG: order ids per status.
SELECT status, LISTAGG(id, ',') WITHIN GROUP (ORDER BY id) AS order_ids
FROM sqmeow_orders GROUP BY status ORDER BY status;

-- Grouping extensions: ROLLUP + CUBE + GROUPING SETS.
SELECT NVL(status, 'ALL') AS status, COUNT(*) AS orders, SUM(total_cents) AS revenue_cents,
       GROUPING(status) AS is_total
FROM sqmeow_orders GROUP BY ROLLUP (status) ORDER BY status;
SELECT status, COUNT(*) AS n FROM sqmeow_orders
GROUP BY CUBE (status) ORDER BY status;
SELECT status, COUNT(*) AS n FROM sqmeow_orders
GROUP BY GROUPING SETS ((status), ()) ORDER BY status;

-- Scratch table lifecycle: insert/update/upsert/delete on a copy, fixtures untouched.
-- Oracle has no DROP ... IF EXISTS: quiet drops keep the first run green,
-- the trailing drops keep reruns green.
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE sqmeow_tmp_adv';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
BEGIN
  EXECUTE IMMEDIATE 'DROP VIEW sqmeow_tmp_adv_view';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
BEGIN
  EXECUTE IMMEDIATE 'DROP SEQUENCE sqmeow_adv_seq';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE sqmeow_tmp_adv_plsql';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
CREATE TABLE sqmeow_tmp_adv (id NUMBER(10) PRIMARY KEY, total_cents NUMBER(10) NOT NULL);
INSERT INTO sqmeow_tmp_adv SELECT id, total_cents FROM sqmeow_orders WHERE status = 'paid';
SELECT COUNT(*) AS copied FROM sqmeow_tmp_adv;
UPDATE sqmeow_tmp_adv SET total_cents = total_cents + 100 WHERE id = 1;
MERGE INTO sqmeow_tmp_adv t USING (SELECT 1 AS id, 9999 AS total_cents FROM dual) s ON (t.id = s.id)
WHEN MATCHED THEN UPDATE SET t.total_cents = s.total_cents
WHEN NOT MATCHED THEN INSERT (id, total_cents) VALUES (s.id, s.total_cents);
SELECT id, total_cents FROM sqmeow_tmp_adv WHERE id = 1;
DELETE FROM sqmeow_tmp_adv WHERE total_cents < 2000;
SELECT COUNT(*) AS remaining FROM sqmeow_tmp_adv;
DROP TABLE sqmeow_tmp_adv;

-- View lifecycle with quiet first drop so reruns stay clean.
BEGIN
  EXECUTE IMMEDIATE 'DROP VIEW sqmeow_tmp_adv_view';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
CREATE VIEW sqmeow_tmp_adv_view AS
SELECT c.city, COUNT(o.id) AS orders FROM sqmeow_customers c
LEFT JOIN sqmeow_orders o ON o.customer_id = c.id GROUP BY c.city;
SELECT * FROM sqmeow_tmp_adv_view ORDER BY city;
DROP VIEW sqmeow_tmp_adv_view;

-- Sequence lifecycle.
BEGIN
  EXECUTE IMMEDIATE 'DROP SEQUENCE sqmeow_adv_seq';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
CREATE SEQUENCE sqmeow_adv_seq START WITH 1 INCREMENT BY 1;
SELECT sqmeow_adv_seq.NEXTVAL AS n1, sqmeow_adv_seq.CURRVAL AS n1_again FROM dual;
DROP SEQUENCE sqmeow_adv_seq;

-- Anonymous PL/SQL block: variables + FOR loop, writes only to a scratch table.
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE sqmeow_tmp_adv_plsql';
EXCEPTION
  WHEN OTHERS THEN NULL;
END;
CREATE TABLE sqmeow_tmp_adv_plsql (n NUMBER(10) PRIMARY KEY, running NUMBER(10));
DECLARE
  v_count NUMBER;
  v_running NUMBER := 0;
BEGIN
  SELECT COUNT(*) INTO v_count FROM sqmeow_customers;
  FOR i IN 1..5 LOOP
    v_running := v_running + i;
  END LOOP;
  INSERT INTO sqmeow_tmp_adv_plsql VALUES (v_count, v_running);
END;
SELECT * FROM sqmeow_tmp_adv_plsql;
DROP TABLE sqmeow_tmp_adv_plsql;

-- Scalar function lifecycle.
CREATE OR REPLACE FUNCTION sqmeow_cents_to_dollars(cents IN NUMBER) RETURN NUMBER DETERMINISTIC IS
BEGIN
  RETURN cents / 100;
END;
SELECT id, total_cents, sqmeow_cents_to_dollars(total_cents) AS dollars
FROM sqmeow_orders ORDER BY id FETCH FIRST 5 ROWS ONLY;
DROP FUNCTION sqmeow_cents_to_dollars;

-- Stored procedure lifecycle: reports the customer count via an OUT parameter.
CREATE OR REPLACE PROCEDURE sqmeow_adv_count_customers(n OUT NUMBER) IS
BEGIN
  SELECT COUNT(*) INTO n FROM sqmeow_customers;
END;
DECLARE
  v_n NUMBER;
BEGIN
  sqmeow_adv_count_customers(v_n);
END;
DROP PROCEDURE sqmeow_adv_count_customers;

-- Query plan for a typical join.
EXPLAIN PLAN FOR SELECT c.name, o.total_cents FROM sqmeow_customers c
JOIN sqmeow_orders o ON o.customer_id = c.id WHERE o.status = 'paid';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
