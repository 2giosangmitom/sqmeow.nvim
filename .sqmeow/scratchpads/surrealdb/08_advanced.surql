-- Advanced smoke checks: run after 02_create (03_read first is fine).
-- Tolerant of 04_update/05_delete results. Read-only against fixtures except
-- the self-cleaning sqmeow_tmp_adv record and sqmeow:: function below.
-- Run statement-by-statement with <CR>.

-- Filter + sort + paging + projection equivalents.
SELECT * FROM sqmeow_orders WHERE total_cents >= 2000 ORDER BY total_cents DESC LIMIT 5 START 2;
SELECT name, city FROM sqmeow_customers WHERE city IN ["Berlin", "Tokyo"] ORDER BY name;
SELECT * FROM sqmeow_customers WHERE email CONTAINS "@example.test" AND note IS NOT NONE ORDER BY id;

-- Variables with LET.
LET $min_total = 2000;
SELECT * FROM sqmeow_orders WHERE total_cents >= $min_total ORDER BY total_cents DESC LIMIT 5;
LET $wanted = "paid";
SELECT status, count() AS n, math::sum(total_cents) AS revenue FROM sqmeow_orders WHERE status = $wanted GROUP BY status;

-- String, math, array, and type functions.
SELECT *, string::uppercase(name) AS upper_name, string::lowercase(city) AS lower_city,
  string::len(email) AS email_len, string::concat(name, " <", email, ">") AS labeled
  FROM sqmeow_customers ORDER BY id LIMIT 5;
SELECT id, total_cents, total_cents / 100 AS dollars, math::round(total_cents / 100) AS rounded,
  math::abs(total_cents - 5000) AS dist_5k FROM sqmeow_orders ORDER BY id LIMIT 5;
RETURN array::sort(array::distinct((SELECT VALUE city FROM sqmeow_customers)));
RETURN array::len(array::distinct((SELECT VALUE city FROM sqmeow_customers)));
SELECT type::is_number(total_cents) AS is_number, type::is_string(note) AS note_is_string
  FROM sqmeow_orders LIMIT 3;

-- Conditional expression.
RETURN IF $min_total > 1000 THEN "high bar" ELSE "low bar" END;

-- FOR loop over a range (returns the squares of 1..5).
FOR $i IN 1..=5 {
  $i * $i
};

-- Grouped revenue with a join fetch.
SELECT status, count() AS orders, math::sum(total_cents) AS revenue
  FROM sqmeow_orders GROUP BY status ORDER BY revenue DESC;
SELECT *, customer_id.name AS customer_name FROM sqmeow_orders
  WHERE total_cents >= $min_total ORDER BY total_cents DESC LIMIT 5 FETCH customer_id;
SELECT *, product_id.name AS product_name, order_id.status AS order_status
  FROM sqmeow_order_items WHERE quantity >= 2 ORDER BY id LIMIT 5 FETCH order_id, product_id;

-- Time functions.
RETURN time::now();
RETURN time::year(time::now());

-- Scratch record lifecycle: create/read/update/delete, fixtures untouched.
CREATE sqmeow_tmp_adv:1 CONTENT { n: 1, note: "one" };
SELECT * FROM sqmeow_tmp_adv:1;
UPDATE sqmeow_tmp_adv:1 SET note = "uno";
SELECT * FROM sqmeow_tmp_adv WHERE n = 1;
DELETE sqmeow_tmp_adv:1;

-- User-defined function lifecycle.
DEFINE FUNCTION fn::sqmeow_cents_to_dollars($c: int) {
  RETURN $c / 100;
};
RETURN fn::sqmeow_cents_to_dollars(1999);
SELECT id, total_cents, fn::sqmeow_cents_to_dollars(total_cents) AS dollars
  FROM sqmeow_orders ORDER BY id LIMIT 5;
REMOVE FUNCTION fn::sqmeow_cents_to_dollars;
