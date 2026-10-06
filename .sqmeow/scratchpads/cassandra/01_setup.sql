CREATE KEYSPACE IF NOT EXISTS sqmeow_quicktest
WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_customers (
  id int PRIMARY KEY,
  name text,
  email text,
  city text,
  active int,
  note text
);

CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_products (
  id int PRIMARY KEY,
  sku text,
  name text,
  category text,
  price_cents int,
  stock_qty int,
  note text
);

CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_orders (
  id int PRIMARY KEY,
  customer_id int,
  ordered_on text,
  status text,
  total_cents int,
  note text
);

CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_order_items (
  id int PRIMARY KEY,
  order_id int,
  product_id int,
  quantity int,
  unit_price_cents int,
  discount_cents int
);

CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_payments (
  id int PRIMARY KEY,
  order_id int,
  paid_on text,
  method text,
  amount_cents int,
  status text,
  note text
);
