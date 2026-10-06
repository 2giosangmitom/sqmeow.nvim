-- Run before 06_cleanup. Buffer execution prompts once per distinct name.
-- Statement/range execution uses these declarations even outside the selection.
-- @param customer_id int = 2
-- @param min_total int = 1000
-- @param status text = shipped
-- @param enabled bool = true
-- @param tax float = 0.075
-- @param optional_note text = NULL

SELECT o.id, c.name, o.status, o.total_cents,
       o.total_cents * (1 + :tax) AS estimated_taxed_cents
FROM sqmeow_orders o
JOIN sqmeow_customers c ON c.id = o.customer_id
WHERE c.id = :customer_id AND o.total_cents >= :min_total
  AND o.status = :status AND :enabled = TRUE
ORDER BY o.id;

SELECT id, name, note FROM sqmeow_customers
WHERE id = :customer_id AND (:optional_note IS NULL OR note = :optional_note);

-- Literal colons and PostgreSQL casts must not become extra prompts.
SELECT ':not_a_parameter' AS literal_text, :customer_id::bigint AS first_id,
       :customer_id AS repeated_id, :optional_note AS nullable_text;
