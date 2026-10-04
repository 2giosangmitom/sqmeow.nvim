# Retained-result view benchmark

Polars is the retained-result view engine; result storage, editing, paging, and
exports still read the original `ResultSet`. Original row indices travel in a
private Polars column, never as page-relative positions. Free-form conditions
use Polars SQL semantics rather than the removed local SQL evaluator.

```sh
cargo run -p sqmeow-db --release --example view_bench -- 100000 10
```

This measures an integer `>=` filter followed by a two-key sort, including
conversion from held cells to a Polars frame. On this workspace, the final
all-Polars path measured 10.3 ms median and 49,720 KiB process peak RSS at
100,000 rows and ten runs. The earlier engine measured 58.2 ms and 19,976 KiB
on the same workload. Re-run the command on your machine; other cell types and
free-form SQL can cost more.
