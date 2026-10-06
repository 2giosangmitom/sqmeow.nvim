-- Run after 04_update and before 06_cleanup.
-- Record IDs and function namespaces remain literal; inputs become SDK variables.
-- @param name text = Bob O'Brien
-- @param status text = shipped
-- @param min_total int = 1000

SELECT * FROM sqmeow_customers WHERE name = :name;

SELECT *, customer_id.name AS customer_name FROM sqmeow_orders
WHERE status = :status AND total_cents >= :min_total
ORDER BY total_cents DESC FETCH customer_id;

RETURN {first: :min_total, repeated: :min_total, literal: ':not_a_parameter'};
