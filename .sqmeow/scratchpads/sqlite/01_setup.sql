CREATE TABLE IF NOT EXISTS sqmeow_customers (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  city TEXT NOT NULL,
  active INTEGER NOT NULL,
  note TEXT
);

CREATE TABLE IF NOT EXISTS sqmeow_products (
  id INTEGER PRIMARY KEY,
  sku TEXT NOT NULL,
  name TEXT NOT NULL,
  category TEXT NOT NULL,
  price_cents INTEGER NOT NULL,
  stock_qty INTEGER NOT NULL,
  note TEXT
);

CREATE TABLE IF NOT EXISTS sqmeow_orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  ordered_on TEXT NOT NULL,
  status TEXT NOT NULL,
  total_cents INTEGER NOT NULL,
  note TEXT,
  CONSTRAINT fk_orders_customer_id FOREIGN KEY (customer_id) REFERENCES sqmeow_customers (id)
);

CREATE TABLE IF NOT EXISTS sqmeow_order_items (
  id INTEGER PRIMARY KEY,
  order_id INTEGER NOT NULL,
  product_id INTEGER NOT NULL,
  quantity INTEGER NOT NULL,
  unit_price_cents INTEGER NOT NULL,
  discount_cents INTEGER NOT NULL,
  CONSTRAINT fk_order_items_order_id FOREIGN KEY (order_id) REFERENCES sqmeow_orders (id),
  CONSTRAINT fk_order_items_product_id FOREIGN KEY (product_id) REFERENCES sqmeow_products (id),
  CONSTRAINT uq_smoke_order_product UNIQUE (order_id, product_id)
);

CREATE TABLE IF NOT EXISTS sqmeow_payments (
  id INTEGER PRIMARY KEY,
  order_id INTEGER NOT NULL,
  paid_on TEXT NOT NULL,
  method TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,
  status TEXT NOT NULL,
  note TEXT,
  CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES sqmeow_orders (id)
);
