CREATE TABLE IF NOT EXISTS sqmeow_crud (
  id Int32,
  name String,
  score Int32,
  active Int32,
  note Nullable(String)
) ENGINE = MergeTree ORDER BY id;
