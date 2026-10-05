CREATE KEYSPACE IF NOT EXISTS sqmeow_quicktest
WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};
CREATE TABLE IF NOT EXISTS sqmeow_quicktest.sqmeow_crud (
  id int PRIMARY KEY,
  name text,
  score int,
  active int,
  note text
);
