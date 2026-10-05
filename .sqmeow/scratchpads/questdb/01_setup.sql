CREATE TABLE IF NOT EXISTS sqmeow_crud (
  id INT,
  name STRING,
  score INT,
  active INT,
  note STRING,
  ts TIMESTAMP
) TIMESTAMP(ts) PARTITION BY DAY WAL;
