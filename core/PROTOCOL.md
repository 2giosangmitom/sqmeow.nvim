# The sqmeow protocol

What the plugin and the engine say to each other. Both sides code against this document; neither
side may change a field without changing it here first.

## The channel

Neovim starts the engine with `vim.fn.jobstart({ bin }, { rpc = true })`, which makes the two
processes msgpack-RPC peers of one another. Traffic runs in both directions:

- The plugin calls the engine with `rpcrequest`, using the methods below.
- The engine calls Neovim's own API directly, both to paint result buffers and to deliver events.

Every event the engine sends arrives through one `nvim_exec_lua` call running
`require('sqmeow.rpc').dispatch(event, payload)`, so the plugin registers no RPC methods of its own.

Every payload in either direction is a single map. Positional arguments are not used anywhere,
which means a field can be added without breaking a peer that does not know about it.

## Versioning

`handshake` reports `protocol_version`, an integer. The plugin holds the version it was written
against and refuses a mismatch with one actionable message rather than failing later on a field
that is not there. The current version is **1**.

Adding a method, adding an optional request field, or adding a field to an event payload does not
change the version. Removing or renaming anything, or changing what a field means, does.

## Requests

Every method answers immediately. A method that touches a database answers with an identifier and
reports the outcome as an event, so the editor is never blocked on a socket.

| Method        | Arguments                                                                                                                                   | Answers with                                          |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `handshake`   | `plugin_version`                                                                                                                            | `core_version`, `protocol_version`, `pid`, `adapters` |
| `ping`        |                                                                                                                                             | `"pong"`                                              |
| `configure`   | `max_rows`, `history_size`, `page_size`, `max_column_width`, `null_text`, `grid_vertical`, `grid_horizontal`, `grid_cross`, `grid_ellipsis` | the settings as applied                               |
| `connect`     | `id`, `url`, `name`                                                                                                                         | `id`; the outcome arrives as `conn:state`             |
| `disconnect`  | `id`                                                                                                                                        | whether there was a connection to close               |
| `connections` |                                                                                                                                             | one map per open connection                           |
| `execute`     | `conn_id`, `sql`, `buf`, `line`                                                                                                             | `call_id`; the outcome arrives as `call:state`        |
| `cancel`      | `call_id`                                                                                                                                   | whether a query was running                           |
| `page`        | `call_id`, `buf`, `offset`, `delta`                                                                                                         | `call_id`; the page arrives as `page:painted`         |
| `row`         | `call_id`, `row`                                                                                                                            | one map per column of that row                        |
| `introspect`  | `conn_id`, `path`                                                                                                                           | `true`; the children arrive as `schema:nodes`         |
| `catalog`     | `conn_id`, `refresh`                                                                                                                        | `true`; the list arrives as `schema:catalog`          |
| `export`      | `call_id`, `format`, `scope`, `row`, `column`, `register`, `path`                                                                           | `call_id`; the outcome arrives as `export:done`       |
| `shutdown`    |                                                                                                                                             | nil, and the engine exits                             |

Notes on the ones with sharp edges:

**`configure`** carries only the fields that changed. Absent fields are left alone, and values
outside a sensible range are clamped rather than rejected, which is why it echoes back what was
actually applied.

**`connect`** takes the connection id from the plugin, not the engine. That lets a connection be
named and drawn in the interface before the engine has finished opening it. A URL may hold
`{{ env "NAME" }}` or `{{ exec "command" }}`, expanded at connect time; the expanded URL is never
logged, echoed, or sent back.

**`execute`** sends the whole buffer along with `line`, the zero-based cursor line, when only the
statement under the cursor should run. The engine splits the text and picks the statement, so what
counts as a statement has one answer rather than one per side.

**`page`** takes either an absolute `offset` in rows or a `delta` in pages, never both. Paging past
either end settles on the first or last page rather than emptying the view.

**`introspect`** takes a path of at most three parts, one level at a time and on demand. An empty
path asks for the connection's schemas. `[schema]` answers with four group headings, `tables`,
`views`, `functions` and `procedures`, each carrying how many things it holds. `[schema, group]`
answers with what that group holds, and `[schema, group, relation]` with a relation's columns. The
group is a heading rather than something the database names anything after, so it takes no part in
a qualified name.

**`catalog`** asks for every relation in every schema at once, which is what the relation picker
searches. The engine holds the answer on the connection, so a second call is free; `refresh` reads
it again. A schema that cannot be read is left out rather than failing the whole list.

**`export`** never sends text back. A hundred thousand rows of CSV would be a very large message
for the editor to decode only to hand straight to `setreg`, so the engine writes into the register
or the file itself. `scope` is `all`, `page`, `row` or `cell`; `path` writes a file and its absence
writes the register named by `register`.

## Events

Sent as notifications, never as requests, so the engine is never blocked on the editor.

### `conn:state`

`id`, `state`, `name`, and then whatever the state carries.

| `state`      | Also carries |
| ------------ | ------------ |
| `connecting` |              |
| `connected`  | `dialect`    |
| `error`      | `error`      |
| `closed`     |              |

### `call:state`

`call_id`, `conn_id`, `state`.

| `state`     | Also carries                                                                 |
| ----------- | ---------------------------------------------------------------------------- |
| `executing` | `statements`, and `start_line` and `end_line` covering what will run         |
| `done`      | the result summary below, and `elapsed_ms`                                   |
| `error`     | `error`, and `start_line` and `end_line` when the failing statement is known |
| `cancelled` | `elapsed_ms`                                                                 |

The result summary, shared with `page:painted`:

| Field                        | Meaning                                                   |
| ---------------------------- | --------------------------------------------------------- |
| `rows`                       | rows held                                                 |
| `columns`                    | column count                                              |
| `affected`                   | rows a statement changed, when it returned none           |
| `truncated`                  | whether the row cap was reached                           |
| `offset`                     | the row the current page starts at                        |
| `page`, `pages`, `page_size` | where the page sits                                       |
| `column_spans`               | one map per column: `name`, `type_name`, `start`, `width` |
| `header_lines`               | how many lines of the buffer come before the first row    |

`start` and `width` are in **display columns**, not bytes, because a byte offset means nothing on a
line holding CJK text. They are what lets the editor tell which cell the cursor is on without
knowing how the grid was laid out.

### `page:painted`

The same summary, sent once the buffer has been written.

### `schema:nodes`

`conn_id`, `path`, `nodes`, and `error` when the level could not be read. Every node carries `name`,
`kind` and `expandable`. A group heading also carries `count` and a `key`, which is the word the
path is built from rather than the label that is drawn: `Tables` is shown, `tables` is sent back. A
column also carries `type_name`, `nullable` and `primary_key`.

### `schema:catalog`

`conn_id`, `relations`, and `error` when the catalog could not be read. Each relation carries
`schema`, `name` and `kind`.

### `export:done`

`call_id`, and then either `error`, or `target` with what it produced: `file` with `path` and
`bytes`, or `register` with `register` and `bytes`.

## Painting

The engine writes result grids into Neovim buffers itself. The plugin allocates a scratch buffer and
passes the handle; the engine batches the modifiable toggle and every `nvim_buf_set_lines` for one
page into a single `nvim_call_atomic`. One round trip paints a page, and no row of data is ever
formatted in Lua.

The column names, the rule under them, and the rows are one block in one buffer. `header_lines` in
the summary is what turns a cursor line into a row of the result, so the editor never has to know
how the grid was laid out.
