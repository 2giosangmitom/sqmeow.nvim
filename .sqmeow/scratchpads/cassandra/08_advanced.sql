-- Advanced CQL checks: run after 02_create. Tolerant of 04_update/05_delete.
-- CQL has no joins, subqueries, window functions, GROUP BY analytics, stored
-- procedures, functions (usually disabled server-side), variables or loops:
-- this file covers everything the fixtures can exercise instead.
-- Run statement-by-statement with <CR>.

-- Point lookups and IN (the primary CQL access path).
SELECT * FROM sqmeow_quicktest.sqmeow_customers WHERE id = 1;
SELECT * FROM sqmeow_quicktest.sqmeow_orders WHERE id = 2;
SELECT * FROM sqmeow_quicktest.sqmeow_order_items WHERE id IN (1, 2, 3);
SELECT id, name, city FROM sqmeow_quicktest.sqmeow_customers WHERE id IN (1, 2, 20);

-- Paging.
SELECT * FROM sqmeow_quicktest.sqmeow_products LIMIT 5;
SELECT id, status, total_cents FROM sqmeow_quicktest.sqmeow_orders LIMIT 10;

-- Token-range scan (how drivers page whole tables internally).
SELECT id, TOKEN(id) FROM sqmeow_quicktest.sqmeow_customers LIMIT 5;
SELECT id FROM sqmeow_quicktest.sqmeow_customers WHERE TOKEN(id) > TOKEN(1) LIMIT 5;

-- Filtered scan; ALLOW FILTERING is required off the primary key.
SELECT id, status, total_cents FROM sqmeow_quicktest.sqmeow_orders
WHERE status = 'paid' ALLOW FILTERING;
SELECT id, name, city FROM sqmeow_quicktest.sqmeow_customers
WHERE city = 'Berlin' ALLOW FILTERING;

-- Whole-table aggregates.
SELECT COUNT(*) FROM sqmeow_quicktest.sqmeow_customers;
SELECT COUNT(*), SUM(total_cents), AVG(total_cents), MIN(total_cents), MAX(total_cents)
FROM sqmeow_quicktest.sqmeow_orders;

-- Cell metadata: TTL and write timestamps (fixtures set no TTL, so TTL is null).
SELECT id, name, TTL(note), WRITETIME(name) FROM sqmeow_quicktest.sqmeow_customers WHERE id = 1;
SELECT id, status, WRITETIME(status) FROM sqmeow_quicktest.sqmeow_orders WHERE id = 2;

-- Secondary index lifecycle on a scratch index.
CREATE INDEX sqmeow_adv_city_idx ON sqmeow_quicktest.sqmeow_customers (city);
SELECT id, name FROM sqmeow_quicktest.sqmeow_customers WHERE city = 'Berlin';
DROP INDEX IF EXISTS sqmeow_quicktest.sqmeow_adv_city_idx;

-- Scratch table lifecycle: insert/update/LWT/delete, fixtures untouched.
CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_tmp_adv (
  id int PRIMARY KEY,
  note text
);
INSERT INTO sqmeow_quicktest.sqmeow_tmp_adv (id, note) VALUES (1, 'one') USING TTL 86400;
UPDATE sqmeow_quicktest.sqmeow_tmp_adv SET note = 'uno' WHERE id = 1 IF EXISTS;
SELECT * FROM sqmeow_quicktest.sqmeow_tmp_adv WHERE id = 1;
DELETE note FROM sqmeow_quicktest.sqmeow_tmp_adv WHERE id = 1 IF EXISTS;
SELECT * FROM sqmeow_quicktest.sqmeow_tmp_adv WHERE id = 1;
DROP TABLE IF EXISTS sqmeow_quicktest.sqmeow_tmp_adv;

-- Logged batch: an insert plus an update applied atomically.
CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_tmp_adv (
  id int PRIMARY KEY,
  note text
);
BEGIN BATCH
  INSERT INTO sqmeow_quicktest.sqmeow_tmp_adv (id, note) VALUES (1, 'one');
  INSERT INTO sqmeow_quicktest.sqmeow_tmp_adv (id, note) VALUES (2, 'two');
  UPDATE sqmeow_quicktest.sqmeow_tmp_adv SET note = 'uno' WHERE id = 1;
APPLY BATCH;
SELECT * FROM sqmeow_quicktest.sqmeow_tmp_adv WHERE id IN (1, 2);
DROP TABLE IF EXISTS sqmeow_quicktest.sqmeow_tmp_adv;
