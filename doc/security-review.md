# Query execution and adapter review

## Confirmed findings addressed

| Finding | Impact | Fix location |
| --- | --- | --- |
| Live visual selections could use old marks; block selections included text outside the rectangle; byte endpoints could cut Unicode characters | Wrong SQL, including unselected destructive statements | `lua/sqmeow/api.lua`, `lua/sqmeow/ui/editor.lua`, `lua/sqmeow/keymap.lua` |
| Explicit `:2,3Sqmeow execute` ranges used previous visual marks instead of the requested lines | Wrong SQL from an unrelated selection | `lua/sqmeow/commands.lua` |
| Read-only checks examined the original query but not SQL assembled from filter/order fragments | High-impact bypass of the plugin's write safeguard on backends without read-only sessions | `core/sqmeow-core/src/core/calls.rs` |
| MongoDB read checks accepted any read-command key and matched write-stage names as raw JSON | Read-only safeguard bypass through extra keys or Unicode-escaped `$out`/`$merge` | `core/sqmeow-db/src/guard.rs` |
| Unsupported-URL errors and automatic labels could expose credentials; query credentials were not redacted | Password/token disclosure to the UI and logs | `core/sqmeow-db/src/error.rs`, `lua/sqmeow/url.lua` |
| PowerShell downloads interpolated unescaped single quotes into executable command text | Local command injection if download arguments contain attacker-controlled quotes | `lua/sqmeow/install.lua` |
| Redis, MongoDB and CQL adapters did not disclose that read-only protection was lexical only | Misleading security expectations | `core/sqmeow-adapters/src/lib.rs` |

SQL Server batching additionally recognizes standalone `GO` with complete trailing block comments. Unclosed comments and SQL after the comment are not discarded. `GO n` repetition and `GO;` are deliberately not supported: silently treating them as ordinary separators changes execution semantics.

## Execution semantics

- Query text is read from the current buffer, not from its saved file. Saving is unnecessary.
- A visual execution runs exactly the selected text, not surrounding declarations or transaction setup.
- SQL Server cursor execution runs a whole `GO` batch, preserving batch-local variables. Semicolons alone do not separate SQL Server requests.
- An explicit Ex range runs complete requested lines; the visual key/API preserves character/block selection boundaries.

## Security boundaries and remaining risks

This review is not a guarantee that the plugin or its dependencies are vulnerability-free. No remotely exploitable critical vulnerability was confirmed by the checks performed.

- Read-only checks and destructive confirmations are lexical safeguards, **not database authorization**. Stored functions, dynamic SQL and dialect-specific syntax cannot be fully classified this way. Use database credentials without write privileges for untrusted queries.
- Connection-source shell commands and `{{ exec }}` directives intentionally execute local commands. Treat connection definitions as executable trusted configuration, never as safe data from an untrusted project.
- RPC is a local subprocess interface, not a sandbox. Exports intentionally write caller-selected paths, and archives contain query results that may be sensitive.
- Export table overrides and grid SQL expressions are trusted SQL fragments. Do not populate them from untrusted data. The export table override remains unquoted for compatibility with qualified/quoted names.
- Explicit TLS bypass options remain opt-in. Do not use them with untrusted networks.
- Credentials embedded in arbitrary driver/server diagnostics or SQL text cannot be universally redacted by URL redaction.

## Regression coverage

`tests/test_selection.lua` exercises stale/live marks, exclusive and rectangular selections, Unicode, explicit ranges and unsaved text for every dialect. `tests/test_buffer_execution.lua` runs selection, range and unsaved-buffer cases against all adapters, including SQL Server variable/GO scope and read-only filter checks.

`core/sqmeow-adapters/tests/query_buffers.rs` exercises splitting, cursor line mapping, execution, repeat requests and cursor row caps across all 11 adapters and protocol variants (Cassandra, CockroachDB, QuestDB, Dragonfly, Redis Cluster and Sentinel). Server cases require their `SQMEOW_TEST_*_URL` variables; `just test-rust` and `just test-lua` discover the Compose fixtures. Missing fixtures are reported as skips, not live coverage.
