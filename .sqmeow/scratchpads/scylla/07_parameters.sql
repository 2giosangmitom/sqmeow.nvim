-- Run before 06_cleanup. CQL values bind through prepared statements.
-- @param customer_id int = 2
-- @param order_id int = 2

SELECT * FROM sqmeow_quicktest.sqmeow_customers WHERE id = :customer_id;

SELECT * FROM sqmeow_quicktest.sqmeow_orders WHERE id = :order_id;

SELECT * FROM sqmeow_quicktest.sqmeow_order_items WHERE id IN (:order_id, :order_id);
