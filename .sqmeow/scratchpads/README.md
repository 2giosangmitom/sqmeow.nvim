# Local adapter smoke tests

Disposable store fixtures for every connection in `.sqmeow/connections.toml`.
Do not run these against production databases. Check the buffer's connection
winbar or bind it explicitly with `:Sqmeow bind <connection>`; folders do not
bind queries to connections.

## Run

1. Start only the database you want to test. SQLite and DuckDB need no container.
2. Connect in `:Sqmeow`, select the connection, and open its local scratchpads.
3. Execute `01_setup`, then `02_create`, then `03_read`.
4. Execute `04_update`, re-run reads, then `05_delete` and read again.
5. Run the adapter's `07_parameters` before cleanup.
6. Run `06_cleanup` when finished. Confirm destructive-operation prompts.

Use `<leader>E` for the whole buffer and `<CR>` for the current statement.
Use a line selection to test range execution. Create files contain 100 rows;
keep them out of repeated runs unless you clean up first.

## Dataset and expected results

Five entities have 20 records each immediately after `02_create`:

| Entity               | Data and relationships                                                  |
| -------------------- | ----------------------------------------------------------------------- |
| `sqmeow_customers`   | Names, emails, cities, active flags and nullable notes                  |
| `sqmeow_products`    | SKUs, categories, integer prices in cents and stock                     |
| `sqmeow_orders`      | Dates, statuses and totals; references customers                        |
| `sqmeow_order_items` | Quantities, historical prices and discounts; references orders/products |
| `sqmeow_payments`    | Methods, amounts and settlement statuses; references orders             |

Customers 1–8 have two orders, 9–12 have one, and 13–20 have none. Every
order has one line item and one payment. Totals equal quantity × unit price
minus discount. Amounts are cents, avoiding floating-point money comparisons.
The seed includes apostrophes, Unicode, nullable notes and literal colons.

- `03_read`: five editable single-table result sets where supported, a
  five-table order-detail join, customer lifetime totals, grouped revenue,
  window ranking and row counts. Try paging, column sorting, retained-result
  filters, row detail, export, history and table structure.
- `04_update`: customer 2 gets an active flag and `updated smoke note`;
  product 2 stock becomes 77; order 2 becomes shipped with `priority delivery`;
  payment 2 becomes settled with `manually verified`.
- `05_delete`: deletes payment 20, line item 20 and order 20, in that order.
  Counts become 20 customers, 20 products, 19 orders, 19 items, and 19 payments.
  Customer/product records remain, so this does not violate foreign keys.
- `06_cleanup`: removes only the five named fixture entities. Redis cleanup
  deletes only the 100 explicitly listed fixture keys, never `FLUSHDB`.

Relational adapters declare four foreign keys and a unique order/product pair.
ClickHouse and CQL retain the same reference fields without FK constraints.
Keep primary keys unchanged when trying staged grid edits. Execution support
does not imply grid editing support on every adapter.

## Parameter checks

Every adapter has a `07_parameters` file. SQL/CQL/SurrealQL use unquoted `:name`;
MongoDB uses whole JSON string values `":name"`; Redis uses whole unquoted command
arguments. Values go through driver binds, server-side ClickHouse parameters,
or typed BSON/Redis command arguments, never SQL/command text interpolation.
Annotations are optional: `42`, `1.25`, `true` and `NULL` become typed values;
other input is text, and `"42"` forces text. Run the examples after `04_update`:

- Accept SQL defaults: customer 2 has shipped orders 2 and 14; both clear the
  minimum total. The second query returns customer 2 with the updated note.
- Execute one statement or range: only its distinct names should prompt,
  while annotations in the buffer header still supply types and defaults.
- Cancel a prompt: no partial execution or replacement of the current result.
- Change `customer_id` to 1, raise `min_total`, or change `status` to exercise
  empty results. Refresh a live result to reuse its supplied values.
- Enter `NULL` for a typed null; `"NULL"` for literal text; an empty input for
  empty text. Try `optional_note` with `updated smoke note`, then a mismatch.
- Invalid integer/bool input must fail before any statement in the buffer runs.
  Repeated names prompt once. The literal `:not_a_parameter` must never prompt.
- Supplied values are not saved as history parameters. SQL defaults, returned
  rows and edit-source metadata (such as Redis keys)
  can be persisted; do not put secrets in either. Restored results cannot reuse
  lost inputs: rerun from the scratchpad to prompt again.

For CQL, accept defaults to fetch customer/order/item 2; the repeated IN value
must bind twice. For SurrealDB, accept defaults to find Bob and shipped orders;
record references remain native record IDs. Oracle returns NULL for empty text.
For MongoDB, enter `2` for `customer_id`, `1000` for `min_total`, and `NULL` for
`note` to check native BSON integer/null filtering. For Redis/Dragonfly, enter
`sqmeow:smoke:customers:2` for `customer_key` and text containing spaces, quotes
or a newline for `note`: it must stay a single argument, not another command.
Redis does not have NULL arguments, so `NULL` is rejected before submission;
enter `"NULL"` for literal text. JSON/Redis files have no annotation defaults.

## Adapter differences

- SQLite and DuckDB connections are in-memory; reconnecting loses the fixtures.
- Oracle and MongoDB setup expect the five entities not to exist. Clean up a
  partial run before retrying. Oracle uses one INSERT per row for compatibility.
  Oracle supports bound SQL/anonymous PL/SQL, but not bound EXPLAIN or stored
  program definitions; these are rejected rather than interpolated.
- ClickHouse uses MergeTree tables and synchronous mutations; sorting keys do
  not enforce uniqueness. Join/window reads require a modern ClickHouse server.
- Cassandra/ScyllaDB use fully qualified `sqmeow_quicktest.sqmeow_*` CQL tables.
  Reads use scans and primary-key lookups, not joins or arbitrary SQL ordering.
  Cleanup leaves the dedicated empty keyspace available for reuse.
- MongoDB uses native JSON commands, five collections and `$lookup`/grouping
  pipelines. IDs are `_id` integers and dates are sortable ISO strings.
- SurrealDB uses five tables with record-valued references and `FETCH` reads
  in the configured namespace/database; dates are ISO strings.
- Redis/Dragonfly use 100 hashes under `sqmeow:smoke:<entity>:<id>`. Reference
  fields are string IDs; absent fields represent null notes. Follow the IDs
  manually rather than expecting joins. `SCAN` may return a cursor other than
  zero; continue scanning with that cursor if needed. Delete checks return 0.

If you ran the older three-row fixtures, their `sqmeow_crud` table/collection or
`sqmeow:crud:1`–`:3` hashes are not touched by these new fixtures.
