# The sqmeow protocol

What the plugin and the engine say to each other. Both sides code against this document; neither
side may change a field without changing it here first.

## The channel

Neovim starts the engine with `vim.fn.jobstart({ bin }, { rpc = true })`, which makes the two
processes msgpack-RPC peers of one another. Traffic runs in both directions:

- The plugin calls the engine with `rpcrequest`, using the methods below.
- The engine calls Neovim's own API to deliver events, and to write an export into a register.

Every event the engine sends arrives through one `nvim_exec_lua` call running
`require('sqmeow.rpc').dispatch(event, payload)`, so the plugin registers no RPC methods of its own.

Every payload in either direction is a single map. Positional arguments are not used anywhere,
which means a field can be added without breaking a peer that does not know about it.

## Versioning

`handshake` reports `protocol_version`, an integer. The plugin holds the version it was written
against and refuses a mismatch with one actionable message rather than failing later on a field
that is not there. The current version is **2**.

Adding a method, adding an optional request field, or adding a field to an event payload does not
change the version. Removing or renaming anything, or changing what a field means, does.

## Requests

Every method answers immediately. A method that touches a database answers with an identifier and
reports the outcome as an event, so the editor is never blocked on a socket.

| Method        | Arguments                                                                                                                                   | Answers with                                          |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `handshake`   | `plugin_version`                                                                                                                            | `core_version`, `protocol_version`, `pid`, `adapters` |
| `ping`        |                                                                                                                                             | `"pong"`                                              |
| `configure`   | `max_rows`, `history_size`                                                                                                                  | the settings as applied                               |
| `connect`     | `id`, `url`, `name`                                                                                                                         | `id`; the outcome arrives as `conn:state`             |
| `disconnect`  | `id`                                                                                                                                        | whether there was a connection to close               |
| `connections` |                                                                                                                                             | one map per open connection                           |
| `execute`     | `conn_id`, `sql`, `line`, `archive`                                                                                                         | `call_id`; the outcome arrives as `call:state`        |
| `restore`     | `path`, `conn_id`                                                                                                                           | `call_id`; the rows arrive as `call:state`            |
| `cancel`      | `call_id`                                                                                                                                   | whether a query was running                           |
| `rows`        | `call_id`, `offset`, `limit`                                                                                                                | one array of values per row                           |
| `row`         | `call_id`, `row`                                                                                                                            | one map per column of that row                        |
| `introspect`  | `conn_id`, `path`                                                                                                                           | `true`; the children arrive as `schema:nodes`         |
| `catalog`     | `conn_id`, `refresh`                                                                                                                        | `true`; the list arrives as `schema:catalog`          |
| `export`      | `call_id`, `format`, `scope`, `row`, `limit`, `column`, `register`, `path`                                                                  | `call_id`; the outcome arrives as `export:done`       |
| `shutdown`    |                                                                                                                                             | nil, and the engine exits                             |

Notes on the ones with sharp edges:

**`configure`** carries only the fields that changed. Absent fields are left alone, and values
outside a sensible range are clamped rather than rejected, which is why it echoes back what was
actually applied. Two settings are all that is left: everything else that used to travel described
how a result should look, and the engine does not draw one.

**`connect`** takes the connection id from the plugin, not the engine. That lets a connection be
named and drawn in the interface before the engine has finished opening it. A URL may hold
`{{ env "NAME" }}` or `{{ exec "command" }}`, expanded at connect time; the expanded URL is never
logged, echoed, or sent back.

**`execute`** sends the whole buffer along with `line`, the zero-based cursor line, when only the
statement under the cursor should run. The engine splits the text and picks the statement, so what
counts as a statement has one answer rather than one per side.

**`execute`** also takes `archive`, a file path. When the query finishes with columns to show, the
engine saves the result there once `done` has been reported, for the plugin's query log to show
again after a restart. A failure to write it is logged rather than reported. The file is msgpack: a
header map (`format = "sqmeow-result"`, `version`, `statement`, `columns`, `rows`, `truncated`,
`affected`, `elapsed_ms`) followed by one array per row, where each cell is a nil, boolean,
integer, float or string, or for every other kind an array led by the kind's name. It is written
through a temporary file and is readable by its owner only.

**`restore`** reads a file `execute` saved and holds it as a new call, reported as `call:state`.
`conn_id` is optional and only says which database the rows came from; nothing is
asked of that connection. A file that is missing, cut short, or not a saved result arrives as an
`error` state.

**`rows`** hands back a slice of a held result: `limit` rows from `offset`, as one array of values
per row, in column order. An offset past the end yields no rows rather than an error, because a
page request can race a result being replaced. How large a page is and which one is on screen are
the editor's to decide, so neither is recorded here and two windows on one result need not agree.

Each value arrives as the msgpack type it really is: a number as a number, a boolean as a boolean,
and SQL `NULL` as nil, which Neovim decodes to `vim.NIL` and so survives being an element of an
array. Everything else arrives as a string, already flattened to a single line — a grid row is one
line, and the escaping has to happen on the side that still holds the original. What `NULL` reads
as is not decided here: that is a presentation question, and the editor answers it.

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
or the file itself. `scope` is `all`, `range`, `row` or `cell`; `range` takes `row` and `limit`,
because only the editor knows which rows are on screen. `path` writes a file and its absence writes
the register named by `register`. Exported values are not flattened the way `rows` flattens them:
an export carries the value, line breaks and full length included, and lets the format's own rules
handle it.

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

The result summary:

| Field       | Meaning                                         |
| ----------- | ----------------------------------------------- |
| `rows`      | rows held                                       |
| `columns`   | one map per column, described below             |
| `affected`  | rows a statement changed, when it returned none |
| `truncated` | whether the row cap was reached                 |

Each entry of `columns` carries `name`, `type_name`, `class` — one of `text`, `number`, `boolean`,
`temporal`, `json`, `uuid`, `binary`, `unknown` — and `key`, which is `primary_key` or
`foreign_key` and is absent on a column that is neither. Alongside those are three measurements
taken over the whole result:

| Field     | Meaning                                                                  |
| --------- | ------------------------------------------------------------------------ |
| `widest`  | display columns taken by the widest value, `NULL`s excluded               |
| `nulls`   | whether any value in the column is `NULL`                                 |
| `numeric` | whether every value is a number, which is what decides right alignment    |

`widest` is in **display columns**, not bytes, and is measured against the same flattened text
`rows` sends, so a value holding a line break is measured as the escape that reaches the grid. It
is capped at 512, far above any sensible column width, so that one megabyte-long value does not
cost a pass over a megabyte to learn it is wide.

These are measured here rather than in the editor for one reason: the editor is sent one page at a
time, and a column sized from the page on screen would change width when the user turned to the
next. `NULL`s are left out of the measurement because what one reads as is the editor's choice, so
only the editor can say how wide one is.

### `schema:nodes`

`conn_id`, `path`, `nodes`, and `error` when the level could not be read. Every node carries `name`,
`kind` and `expandable`. A group heading also carries `count` and a `key`, which is the word the
path is built from rather than the label that is drawn: `Tables` is shown, `tables` is sent back. A
column also carries `type_name`, `nullable`, `primary_key`, `class` — one of the eight type classes
above — and `references`, the qualified column a foreign key points at, such as `authors.id`, absent
on a column that points at nothing.

### `schema:catalog`

`conn_id`, `relations`, and `error` when the catalog could not be read. Each relation carries
`schema`, `name` and `kind`.

### `export:done`

`call_id`, and then either `error`, or `target` with what it produced: `file` with `path` and
`bytes`, or `register` with `register` and `bytes`.

## Drawing

The engine does not draw. It holds the rows a query produced and hands over the slice the editor
asks for; turning that into a grid is the plugin's work, and it does it with
[nui.nvim](https://github.com/MunifTanjim/nui.nvim). No buffer is written from this side and no
highlight is placed from it.

What the engine still owes the editor is the one thing the editor cannot work out for itself: how
wide each column's widest value is, measured over every row rather than over the page on screen.
That measurement is in the result summary above, and it is what lets the grid pin a column's width
so that paging does not make the columns move.
