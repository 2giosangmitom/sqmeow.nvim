CREATE TABLE IF NOT EXISTS sqmeow_customers (
  id Int32,
  name String,
  email String,
  city String,
  active Int32,
  note Nullable(String)
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS sqmeow_products (
  id Int32,
  sku String,
  name String,
  category String,
  price_cents Int32,
  stock_qty Int32,
  note Nullable(String)
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS sqmeow_orders (
  id Int32,
  customer_id Int32,
  ordered_on Date,
  status String,
  total_cents Int32,
  note Nullable(String)
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS sqmeow_order_items (
  id Int32,
  order_id Int32,
  product_id Int32,
  quantity Int32,
  unit_price_cents Int32,
  discount_cents Int32
) ENGINE = MergeTree ORDER BY id;

CREATE TABLE IF NOT EXISTS sqmeow_payments (
  id Int32,
  order_id Int32,
  paid_on Date,
  method String,
  amount_cents Int32,
  status String,
  note Nullable(String)
) ENGINE = MergeTree ORDER BY id;
