-- QuestDB has no row-level DELETE. This partition contains only fixture row 3.
-- Wait for WAL inserts to appear in 03_read before dropping the partition.
ALTER TABLE sqmeow_crud DROP PARTITION LIST '2026-01-01';
SELECT * FROM sqmeow_crud ORDER BY id;
