-- Run after 04_update and before 06_cleanup.
-- Native binding reserves @P<number>; ordinary local/system variables stay native.
-- @param customer_id int = 2
-- @param min_total int = 1000
-- @param status text = shipped
-- @param optional_note text = NULL

SELECT o.id, c.name, o.status, o.total_cents
FROM dbo.sqmeow_orders o
JOIN dbo.sqmeow_customers c ON c.id = o.customer_id
WHERE c.id = :customer_id AND o.total_cents >= :min_total
  AND o.status = :status
ORDER BY o.id;

SELECT id, name, note FROM dbo.sqmeow_customers
WHERE id = :customer_id AND (:optional_note IS NULL OR note = :optional_note);

SELECT ':not_a_parameter' AS literal_text,
       :customer_id AS first_id, :customer_id AS repeated_id;
