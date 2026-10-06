SELECT * FROM sqmeow_quicktest.sqmeow_customers;

SELECT * FROM sqmeow_quicktest.sqmeow_products;

SELECT * FROM sqmeow_quicktest.sqmeow_orders;

SELECT * FROM sqmeow_quicktest.sqmeow_order_items;

SELECT * FROM sqmeow_quicktest.sqmeow_payments;

SELECT id, customer_id, status, total_cents FROM sqmeow_quicktest.sqmeow_orders WHERE id = 2;

SELECT id, order_id, product_id, quantity FROM sqmeow_quicktest.sqmeow_order_items WHERE id IN (1, 2, 3);
