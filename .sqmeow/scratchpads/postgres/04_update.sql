UPDATE sqmeow_customers SET note = 'updated smoke note', active = 1 WHERE id = 2;

SELECT * FROM sqmeow_customers WHERE id = 2;

UPDATE sqmeow_products SET stock_qty = 77 WHERE id = 2;

SELECT * FROM sqmeow_products WHERE id = 2;

UPDATE sqmeow_orders SET status = 'shipped', note = 'priority delivery' WHERE id = 2;

SELECT * FROM sqmeow_orders WHERE id = 2;

UPDATE sqmeow_payments SET status = 'settled', note = 'manually verified' WHERE id = 2;

SELECT * FROM sqmeow_payments WHERE id = 2;
