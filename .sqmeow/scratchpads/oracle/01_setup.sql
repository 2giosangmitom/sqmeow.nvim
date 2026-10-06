CREATE TABLE sqmeow_customers (
  id NUMBER(10) PRIMARY KEY,
  name VARCHAR2(120) NOT NULL,
  email VARCHAR2(120) NOT NULL,
  city VARCHAR2(120) NOT NULL,
  active NUMBER(10) NOT NULL,
  note VARCHAR2(240)
);

CREATE TABLE sqmeow_products (
  id NUMBER(10) PRIMARY KEY,
  sku VARCHAR2(120) NOT NULL,
  name VARCHAR2(120) NOT NULL,
  category VARCHAR2(120) NOT NULL,
  price_cents NUMBER(10) NOT NULL,
  stock_qty NUMBER(10) NOT NULL,
  note VARCHAR2(240)
);

CREATE TABLE sqmeow_orders (
  id NUMBER(10) PRIMARY KEY,
  customer_id NUMBER(10) NOT NULL,
  ordered_on DATE NOT NULL,
  status VARCHAR2(120) NOT NULL,
  total_cents NUMBER(10) NOT NULL,
  note VARCHAR2(240),
  CONSTRAINT fk_orders_customer_id FOREIGN KEY (customer_id) REFERENCES sqmeow_customers (id)
);

CREATE TABLE sqmeow_order_items (
  id NUMBER(10) PRIMARY KEY,
  order_id NUMBER(10) NOT NULL,
  product_id NUMBER(10) NOT NULL,
  quantity NUMBER(10) NOT NULL,
  unit_price_cents NUMBER(10) NOT NULL,
  discount_cents NUMBER(10) NOT NULL,
  CONSTRAINT fk_order_items_order_id FOREIGN KEY (order_id) REFERENCES sqmeow_orders (id),
  CONSTRAINT fk_order_items_product_id FOREIGN KEY (product_id) REFERENCES sqmeow_products (id),
  CONSTRAINT uq_smoke_order_product UNIQUE (order_id, product_id)
);

CREATE TABLE sqmeow_payments (
  id NUMBER(10) PRIMARY KEY,
  order_id NUMBER(10) NOT NULL,
  paid_on DATE NOT NULL,
  method VARCHAR2(120) NOT NULL,
  amount_cents NUMBER(10) NOT NULL,
  status VARCHAR2(120) NOT NULL,
  note VARCHAR2(240),
  CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES sqmeow_orders (id)
);
