IF OBJECT_ID(N'dbo.sqmeow_customers', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_customers (
    id INTEGER PRIMARY KEY,
    name NVARCHAR(120) NOT NULL,
    email NVARCHAR(120) NOT NULL,
    city NVARCHAR(120) NOT NULL,
    active INTEGER NOT NULL,
    note NVARCHAR(240)
  );
END;

IF OBJECT_ID(N'dbo.sqmeow_products', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_products (
    id INTEGER PRIMARY KEY,
    sku NVARCHAR(120) NOT NULL,
    name NVARCHAR(120) NOT NULL,
    category NVARCHAR(120) NOT NULL,
    price_cents INTEGER NOT NULL,
    stock_qty INTEGER NOT NULL,
    note NVARCHAR(240)
  );
END;

IF OBJECT_ID(N'dbo.sqmeow_orders', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_orders (
    id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    ordered_on DATE NOT NULL,
    status NVARCHAR(120) NOT NULL,
    total_cents INTEGER NOT NULL,
    note NVARCHAR(240),
    CONSTRAINT fk_orders_customer_id FOREIGN KEY (customer_id) REFERENCES dbo.sqmeow_customers (id)
  );
END;

IF OBJECT_ID(N'dbo.sqmeow_order_items', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_order_items (
    id INTEGER PRIMARY KEY,
    order_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price_cents INTEGER NOT NULL,
    discount_cents INTEGER NOT NULL,
    CONSTRAINT fk_order_items_order_id FOREIGN KEY (order_id) REFERENCES dbo.sqmeow_orders (id),
    CONSTRAINT fk_order_items_product_id FOREIGN KEY (product_id) REFERENCES dbo.sqmeow_products (id),
    CONSTRAINT uq_smoke_order_product UNIQUE (order_id, product_id)
  );
END;

IF OBJECT_ID(N'dbo.sqmeow_payments', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_payments (
    id INTEGER PRIMARY KEY,
    order_id INTEGER NOT NULL,
    paid_on DATE NOT NULL,
    method NVARCHAR(120) NOT NULL,
    amount_cents INTEGER NOT NULL,
    status NVARCHAR(120) NOT NULL,
    note NVARCHAR(240),
    CONSTRAINT fk_payments_order_id FOREIGN KEY (order_id) REFERENCES dbo.sqmeow_orders (id)
  );
END;
