SELECT * FROM sqmeow_customers ORDER BY id;

SELECT * FROM sqmeow_products ORDER BY id;

SELECT * FROM sqmeow_orders ORDER BY id;

SELECT * FROM sqmeow_order_items ORDER BY id;

SELECT * FROM sqmeow_payments ORDER BY id;

SELECT *, customer_id.name AS customer_name FROM sqmeow_orders WHERE total_cents >= 2000 ORDER BY total_cents DESC FETCH customer_id;

SELECT *, product_id.name AS product_name FROM sqmeow_order_items WHERE order_id.status = "shipped" FETCH order_id, product_id;

SELECT status, count() AS order_count, math::sum(total_cents) AS revenue_cents FROM sqmeow_orders GROUP BY status;
