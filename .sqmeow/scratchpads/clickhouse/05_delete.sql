ALTER TABLE sqmeow_payments DELETE WHERE id = 20 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_payments WHERE id = 20;

ALTER TABLE sqmeow_order_items DELETE WHERE id = 20 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_order_items WHERE id = 20;

ALTER TABLE sqmeow_orders DELETE WHERE id = 20 SETTINGS mutations_sync = 1;

SELECT * FROM sqmeow_orders WHERE id = 20;
