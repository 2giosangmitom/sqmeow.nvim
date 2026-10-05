ALTER TABLE sqmeow_crud DELETE WHERE id = 3 SETTINGS mutations_sync = 1;
SELECT * FROM sqmeow_crud ORDER BY id;
