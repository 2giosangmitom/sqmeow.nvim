UPDATE sqmeow_customers:2 SET active = 1, note = "updated smoke note";
SELECT * FROM sqmeow_customers:2;

UPDATE sqmeow_products:2 SET stock_qty = 77;
SELECT * FROM sqmeow_products:2;

UPDATE sqmeow_orders:2 SET status = "shipped", note = "priority delivery";
SELECT * FROM sqmeow_orders:2;

UPDATE sqmeow_payments:2 SET status = "settled", note = "manually verified";
SELECT * FROM sqmeow_payments:2;
