ALTER TABLE sqmeow_crud UPDATE score = 25, note = 'updated' WHERE id = 2 SETTINGS mutations_sync = 1;
SELECT * FROM sqmeow_crud WHERE id = 2;
