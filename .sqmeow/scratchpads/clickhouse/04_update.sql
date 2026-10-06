ALTER TABLE sqmeow_customers UPDATE note = 'updated smoke note', active = 1 WHERE id = 2 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_customers WHERE id = 2;

ALTER TABLE sqmeow_products UPDATE stock_qty = 77 WHERE id = 2 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_products WHERE id = 2;

ALTER TABLE sqmeow_orders UPDATE status = 'shipped', note = 'priority delivery' WHERE id = 2 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_orders WHERE id = 2;

ALTER TABLE sqmeow_payments UPDATE status = 'settled', note = 'manually verified' WHERE id = 2 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_payments WHERE id = 2;
