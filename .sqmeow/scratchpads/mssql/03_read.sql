SELECT * FROM dbo.sqmeow_customers ORDER BY id;

SELECT * FROM dbo.sqmeow_products ORDER BY id;

SELECT * FROM dbo.sqmeow_orders ORDER BY id;

SELECT * FROM dbo.sqmeow_order_items ORDER BY id;

SELECT * FROM dbo.sqmeow_payments ORDER BY id;

SELECT c.id, c.name, c.city, COUNT(NULLIF(o.id, 0)) AS order_count,
       COALESCE(SUM(o.total_cents), 0) AS lifetime_cents
FROM dbo.sqmeow_customers c
LEFT JOIN dbo.sqmeow_orders o ON o.customer_id = c.id
GROUP BY c.id, c.name, c.city
ORDER BY lifetime_cents DESC, c.id;

SELECT o.id AS order_id, c.name AS customer_name, o.status AS order_status,
       p.sku, p.category, i.quantity, i.unit_price_cents,
       i.quantity * i.unit_price_cents - i.discount_cents AS line_total_cents,
       pay.method, pay.status AS payment_status, pay.amount_cents
FROM dbo.sqmeow_orders o
JOIN dbo.sqmeow_customers c ON c.id = o.customer_id
JOIN dbo.sqmeow_order_items i ON i.order_id = o.id
JOIN dbo.sqmeow_products p ON p.id = i.product_id
LEFT JOIN dbo.sqmeow_payments pay ON pay.order_id = o.id
WHERE o.total_cents >= 2000
ORDER BY o.id, i.id;

WITH totals AS (
  SELECT c.city, p.category, SUM(i.quantity) AS units,
         SUM(i.quantity * i.unit_price_cents - i.discount_cents) AS revenue_cents
  FROM dbo.sqmeow_order_items i
  JOIN dbo.sqmeow_orders o ON o.id = i.order_id
  JOIN dbo.sqmeow_customers c ON c.id = o.customer_id
  JOIN dbo.sqmeow_products p ON p.id = i.product_id
  WHERE o.status <> 'cancelled'
  GROUP BY c.city, p.category
)
SELECT city, category, units, revenue_cents,
       DENSE_RANK() OVER (PARTITION BY city ORDER BY revenue_cents DESC) AS city_rank
FROM totals
ORDER BY city, city_rank, category;

SELECT 'customers' AS entity, COUNT(*) AS row_count FROM dbo.sqmeow_customers UNION ALL
SELECT 'products' AS entity, COUNT(*) AS row_count FROM dbo.sqmeow_products UNION ALL
SELECT 'orders' AS entity, COUNT(*) AS row_count FROM dbo.sqmeow_orders UNION ALL
SELECT 'order_items' AS entity, COUNT(*) AS row_count FROM dbo.sqmeow_order_items UNION ALL
SELECT 'payments' AS entity, COUNT(*) AS row_count FROM dbo.sqmeow_payments;
