IF OBJECT_ID(N'dbo.sqmeow_crud', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.sqmeow_crud (
    id INT PRIMARY KEY,
    name NVARCHAR(80) NOT NULL,
    score INT NOT NULL,
    active INT NOT NULL,
    note NVARCHAR(200)
  );
END;
