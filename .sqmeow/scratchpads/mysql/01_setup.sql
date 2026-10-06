CREATE TABLE IF NOT EXISTS sqmeow_customers (
  id INTEGER PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  email VARCHAR(120) NOT NULL,
  city VARCHAR(120) NOT NULL,
  active INTEGER NOT NULL,
  note VARCHAR(240)
);

CREATE TABLE IF NOT EXISTS sqmeow_products (
  id INTEGER PRIMARY KEY,
  sku VARCHAR(120) NOT NULL,
  name VARCHAR(120) NOT NULL,
  category VARCHAR(120) NOT NULL,
  price_cents INTEGER NOT NULL,
  stock_qty INTEGER NOT NULL,
  note VARCHAR(240)
);

CREATE TABLE IF NOT EXISTS sqmeow_orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL,
  ordered_on DATE NOT NULL,
  status VARCHAR(120) NOT NULL,
  total_cents INTEGER NOT NULL,
  note VARCHAR(240),
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
  paid_on DATE NOT NULL,
  method VARCHAR(120) NOT NULL,
  amount_cents INTEGER NOT NULL,
  status VARCHAR(120) NOT NULL,
  note VARCHAR(240),
  CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES sqmeow_orders (id)
);
