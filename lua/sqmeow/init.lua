--- Browse databases, run queries, and edit results inside Neovim.
---
--- The Lua plugin owns buffers and windows; a separate Rust engine owns database
--- connections and results. Install both with |sqmeow-installation|, then follow
--- |sqmeow-quickstart|. Use |sqmeow-commands| for commands and |sqmeow-api| for Lua.
---@tag sqmeow.nvim
---@toc_entry Introduction

--- Contents ~
---@toc

--- Installation ~
---
--- Requires Neovim 0.10+ and nui.nvim for the drawer, grid, and dialogs. A Nerd
--- Font supplies the default icons; glyphs can be replaced in |sqmeow-config|.
--- With lazy.nvim: >lua
---   {
---     '2giosangmitom/sqmeow.nvim',
---     version = '*',
---     dependencies = { 'MunifTanjim/nui.nvim' },
---     build = function() require('sqmeow').install() end,
---     opts = {},
---     cmd = 'Sqmeow',
---   }
--- <
--- The build hook downloads the matching engine release. To track master,
--- omit `version` and use `install('cargo')`; building requires the repository's
--- Rust toolchain and DuckDB. Run `:checkhealth sqmeow` after installation.
--- Installation methods and asynchronous callbacks: |sqmeow.install()|.
---@tag sqmeow-installation
---@toc_entry Installation

--- Quick start ~
---
--- 1. Run `:Sqmeow` to open the drawer and result window.
--- 2. Press `A` to add a connection, or create |sqmeow-project| configuration.
--- 3. Press <CR> on a connection to open it; `u` selects it for queries.
--- 4. Press `a` to create a scratchpad, such as `example.sql`.
--- 5. Write `SELECT 1;`, then press <CR> to run the statement under the cursor.
---
--- In a scratchpad, visual <CR> runs the selection and <leader>E runs the whole
--- buffer. In the result, `L`/`H` change pages and `K` shows the full row.
--- Press `?` in the drawer or result for local mappings. Closing a window does
--- not disconnect its database; use `:Sqmeow disconnect` when finished.
---@tag sqmeow-quickstart
---@toc_entry Quick start

--- Commands ~
---
--- `:Sqmeow` opens the drawer and result window. Subcommands and supported
--- arguments complete with <Tab>. Brackets below mark optional arguments.
---
--- Connections:
---   :Sqmeow add                  Create a connection using the form.
---   :Sqmeow save [name url]      Save the URL, or prompt for the current one.
---   :Sqmeow edit [name]          Edit a saved connection; otherwise choose one.
---   :Sqmeow remove {name}        Delete a saved entry and close its connection.
---   :Sqmeow use [name]           Select an open connection or choose one.
---   :Sqmeow bind [name|none]     Pin this buffer, clear its pin, or show it.
---   :Sqmeow disconnect          Close the current connection and its children.
---
--- Queries and results:
---   :Sqmeow scratch [name]       Create a named scratchpad, or prompt.
---   :Sqmeow execute [sql]        Run SQL, or the whole buffer when omitted.
---   :[range]Sqmeow execute      Run an inclusive line range.
---   :Sqmeow statement           Run the statement under the cursor.
---   :Sqmeow cancel              Request cancellation of a query or edit apply.
---   :Sqmeow next / prev         Change the displayed result page.
---   :Sqmeow review              Review staged edits before applying them.
---   :Sqmeow export [format] [path|clipboard]
---                               Export as csv, json, or sql; prompt if no path.
---   :Sqmeow log [clear]         Reopen a logged result, or clear saved history.
---
--- Windows and engine:
---   :Sqmeow toggle              Show both windows, or hide them if visible.
---   :Sqmeow drawer              Open the drawer.
---   :Sqmeow open / close        Show or hide the result window.
---   :Sqmeow float               Move the result between a split and a float.
---   :Sqmeow install [method] [version]
---                               Install by download or cargo build.
---   :Sqmeow start / stop / restart
---                               Manage the database engine process.
---   :Sqmeow messages            Show recent engine log messages.
---   :Sqmeow health              Run :checkhealth sqmeow.
---
--- For project, environment, and command sources, edit the original source.
--- `remove` can close their open connections but cannot delete their definitions.
--- Stopping or restarting the engine closes connections and loses in-memory
--- results; archived results remain available through |sqmeow-history|.
---@tag sqmeow-commands
---@toc_entry Commands

--- Making a connection ~
---
--- `:Sqmeow add` (or `A` in the drawer) builds a URL from named fields. Choose
--- `Connection string` to paste a URL, including driver options or templates.
--- `e` edits a saved entry; URL, read-only, and SSH changes take effect on the
--- next connection, while renaming updates the open connection's label.
---
--- Leave the database empty to browse databases on the server where supported.
--- PostgreSQL databases open as child connections named `connection/database`.
--- `:Sqmeow use` selects an open connection; it does not open a saved one.
--- Lua callers can open saved entries with |sqmeow.require('sqmeow.api.connection').connect_named()|.
---
--- Common URL forms: >text
---   postgres://user:password@localhost:5432/app
---   mysql://user:password@localhost:3306/app
---   mssql://sa:password@localhost:1433/master
---   sqlite:/absolute/path/app.db
---   duckdb:/absolute/path/app.duckdb
---   redis://localhost:6379/0
---   mongodb://localhost:27017/app
---   scylla://localhost:9042/keyspace
---   surrealdb://root:password@localhost:8000/namespace/database
---   clickhouse://localhost:8123/default
---   oracle://user:password@localhost:1521/FREEPDB1
--- <
--- In URLs, percent-encode reserved characters in credentials, such as `@` as
--- `%40`. The form and project field loader encode credentials for you.
--- For Redis Cluster or Sentinel, use a URL source with `redis+cluster://` or
--- `redis+sentinel://`; these modes are not fields in project TOML.
---@tag sqmeow-connecting
---@toc_entry Making a connection

--- Connection sources ~
---
--- Project definitions and saved connections are always loaded, in that order.
--- A duplicate name reports a conflict and the project entry wins.
--- A failing source reports a problem without hiding other sources' entries.
--- Loading definitions does not connect to their databases.
---
---   project   Nearest .sqmeow/connections.toml; see |sqmeow-project|.
---   file      JSON array in core.path/connections.json.
---
--- Saved connections use this format: >json
---   [
---     {
---       "name": "dev",
---       "url": "postgres://app@localhost/dev",
---       "read_only": true,
---       "ssh": "user@bastion"
---     }
---   ]
--- <
--- Only `name` and `url` are required. `read_only` defaults to false; omit `ssh`
--- for a direct connection. Set `core.path` to relocate saved connections along
--- with the plugin's other persistent files. Source order is not configurable.
---
--- Adding and saving write to `core.path/connections.json`. They never rewrite
--- project TOML. Environment and command connection sources are not supported;
--- credential templates such as `{{ env "PGPASSWORD" }}` still work.
---@tag sqmeow-sources
---@toc_entry Connection sources

--- Project connections ~
---
--- Search starts at the current window's working directory (`:pwd`) and walks
--- upward for `.sqmeow/connections.toml`. The nearest file wins; parent configs
--- are not merged. Discovery follows `:cd`, `:lcd`, and `:tcd`, not the current
--- buffer's filename. The file is reread whenever sources are loaded: >toml
---   [dev_db]
---   type = "postgres"
---   host = "localhost"
---   port = 5432
---   database = "my_app_dev"
---   user = "dev_user"
---   password = '{{ env "PGPASSWORD" }}'
---   read_only = true
---
---   [local_sqlite]
---   type = "sqlite"
---   path = ".sqmeow/test.db"
--- <
--- Each section supplies the connection name; quote names containing dots, as
--- in `["app.dev"]`. Choose either a complete `url` or `type` with dialect fields.
--- Supported types are:
---   postgres, mysql, mssql, sqlite, duckdb, redis, mongodb, scylla,
---   surrealdb, clickhouse, oracle.
---
--- URL entries need no `type` and may also set `read_only` and `ssh`. Do not mix
--- `url` with `type`, `host`, `path`, or other connection fields: >toml
---   [dev_url]
---   url = "{{ env 'DATABASE_URL' }}"
---   read_only = true
--- <
--- The engine reads `.env` beside `.sqmeow/` when connecting, using dotenvy.
--- Process variables take precedence over the file; a missing file is ignored.
--- Dotenv values are scoped to that connection, never added to the process
--- environment or sent back to Neovim. Single, double, and backtick quotes work
--- in `env` directives. This also supports field-level credential templates.
--- Reconnect after changing `.env`, and keep it out of version control. Dotenv
--- files are plaintext, not encrypted secrets storage.
---
--- Fields follow the chosen dialect's form:
---   host, database, user, password   Strings; host defaults to localhost.
---   port                             Integer, 1-65535; omitted uses driver default.
---   read_only                        Boolean; defaults to false.
---   ssh                              String naming the tunnel host.
---   options                          URL query string for dialects supporting it.
---   tls                              Boolean for Redis, SurrealDB, ClickHouse,
---                                    and Oracle.
---   srv                              Boolean for MongoDB; omit port when true.
---   namespace                        String for SurrealDB.
---   path                             Required string for SQLite and DuckDB.
---
--- Relative database paths resolve from the directory containing `.sqmeow`,
--- even when Neovim is in a child directory. `path = ":memory:"` creates an empty
--- in-memory database: its data is lost when the connection closes. Use a file
--- path to retain data between sessions. Absolute paths are used as given.
---
--- Missing configs are ignored. Invalid TOML, unsupported fields, or wrong value
--- types reject the entire file and report its path. Other sources still load.
--- Reading TOML starts the engine if needed, so use a matching engine build.
--- Project files reject `exec` templates; `env` and `file` templates are supported.
--- If a same-named open connection has different URL, read-only, or SSH settings,
--- disconnect it before connecting to the current project's definition.
--- Edit these connections directly in TOML. Project discovery is always enabled.
---@tag sqmeow-project
---@toc_entry Project connections

--- Credentials and SSH ~
---
--- URL templates resolve in the engine when connecting: >text
---   {{ env "PGPASSWORD" }}          Read an environment variable.
---   {{ file "~/.secrets/database" }} Read a UTF-8 file; trim trailing whitespace.
---   {{ exec "pass show db/dev" }}    Run a shell command; trim trailing whitespace.
--- <
--- Commands have a 30-second deadline. Expansion is not recursive, and values
--- are inserted literally, not URL-encoded. Templates use the engine process's
--- environment; restart it after changing environment variables in Neovim.
--- Expanded URLs are not sent back to the editor. `redact_urls` masks passwords
--- in displayed URLs; it does not encrypt saved connection definitions.
---
--- Set `ssh = "user@bastion"` or a Host alias from `~/.ssh/config` to tunnel a
--- network connection. OpenSSH uses your existing config, keys, and agent. A
--- custom SSH port can be written as `user@bastion:2222`. The database host is
--- resolved from the SSH server; `localhost` means that remote machine.
---@tag sqmeow-credentials
---@toc_entry Credentials and SSH

--- Which database a query runs on ~
---
--- `:Sqmeow use` chooses the active open connection. To keep a buffer on a
--- specific database, use `:Sqmeow bind dev`; this sets `b:sqmeow_connection`.
--- `:Sqmeow bind` shows the binding and `:Sqmeow bind none` clears it.
---
--- A bound buffer requires that named connection to be open. It never silently
--- falls back to another connection. An unbound buffer uses the active one;
--- execution fails if there is none. See |sqmeow.require('sqmeow.api.connection').target()| for Lua callers.
---@tag sqmeow-active
---@toc_entry Which database a query runs on

--- Query and result workflow ~
---
--- Use `:Sqmeow statement` for the statement under the cursor, `:Sqmeow execute`
--- for the buffer, or `:'<,'>Sqmeow execute` for selected lines. Scratchpad
--- mappings are listed under |sqmeow-keymaps|. SQL scripts can return multiple
--- results; `]r` and `[r` switch between them.
---
--- `query.max_rows` caps retained rows per result (0 means unlimited). Reaching
--- the cap marks the result truncated. `ui.result.page_size` controls how many
--- retained rows the grid displays per page; increasing it does not fetch rows
--- beyond the cap. `query.timeout_ms` cancels long-running work; 0 disables it.
--- <C-c> or `:Sqmeow cancel` requests cancellation manually.
---
--- Parameterized scratchpads ~
--- SQL/CQL adapters and SurrealDB accept named values such as
--- `:user_id`. The usual statement, selection and buffer actions prompt once
--- per distinct name. Cancel any prompt to leave the current result and edits
--- alone. Parameter names are case-sensitive and contain ASCII letters, digits
--- and underscores, beginning with a letter or underscore.
---
--- No declaration is needed: input integers, finite decimals and true/false bind
--- as native numbers/booleans; other input binds as text. Use a JSON string such
--- as `"42"` to force text. Header comments optionally declare a type and default: >sql
---   -- @param user_id int = 42
---   -- @param status text = active
---   SELECT * FROM users WHERE id = :user_id AND status = :status;
--- <
--- Types are `text`, `int` (signed 64-bit), `float` (finite), and `bool`
--- (`true`/`false`). Input `NULL` binds a typed null; empty text stays empty.
--- For literal text such as NULL, use a JSON string: `"NULL"`. Values bind through
--- the driver, never through SQL interpolation. Parameters cannot replace table
--- or column names, and cannot mix with native positional placeholders.
--- Strings, quoted identifiers, comments and PostgreSQL casts are left alone.
--- Inside PostgreSQL array subscripts, parenthesize inputs: `items[(:index)]`;
--- an unparenthesized colon is treated as a slice separator.
--- Selection/range actions use declarations from the source buffer's header.
---
--- Lua callers can skip prompts with raw input strings: >lua
---   require('sqmeow.api.query').execute(sql, { parameters = { user_id = '42' } })
--- <
--- An empty parameter map uses declared defaults; missing required values fail
--- before any statement runs. Live-result refreshes reuse the values in memory.
--- Supplied values are not saved as history parameters, but returned rows and
--- edit-source metadata (including Redis keys) may be archived. After restart
--- or result eviction, rerun from the scratchpad to
--- enter values again. Keep secrets out of defaults, which are part of the SQL.
--- Unannotated NULL uses a text null; declare the type when the SQL context needs
--- a numeric/boolean null. Driver-specific value limits still apply. Oracle
--- treats empty strings as NULL, following its own database semantics.
--- Oracle bound EXPLAIN and stored-program definitions are not yet supported;
--- ordinary bound SQL and anonymous PL/SQL blocks use native named binds.
---
--- MongoDB uses whole JSON string values, not raw JSON substitution: >json
---   {"find":"users","filter":{"name":":name","age":{"$gte":":age"}}}
--- <
--- Values bind as BSON scalars; command, database, collection and field names
--- cannot be parameters. Aggregation expression operands require `$literal`,
--- for example `{"$project":{"value":{"$literal":":value"}}}`. Executable
--- JavaScript and structural stage options cannot be parameters.
--- Bind ordinary scalars, not fields inside Extended JSON type wrappers.
--- Redis/Valkey/Dragonfly use whole unquoted arguments: >
---   HSET user:1 name :name
--- <
--- A supplied value stays one Redis argument even with spaces or newlines.
--- Quoted `':name'` stays literal. Redis has no NULL command argument; use empty
--- text instead. Redis script bodies/subcommands cannot be bound parameters.
--- Neither adapter changes or reparses the user's query source.
---
--- Filtering and sorting ~
--- `gf` opens WHERE and `go` opens ORDER BY above the grid. Enter expressions
--- without the clause keyword; <CR> applies them. `=` filters by the current
--- cell, `s` cycles column sorting, and `S` adds another sort column.
--- Every adapter uses Polars SQL on retained rows, including MongoDB and other
--- NoSQL results, disconnected connections, and restored history. Filtering
--- preserves staged edits without rerunning the database query. It covers every
--- retained page but cannot recover rows omitted by the query or `query.max_rows`.
--- `R` clears filters, sorting, and hidden columns, restoring the snapshot.
--- Run the original query again for fresh data. Refreshing after applying edits
--- reapplies the local view to the new result.
---
--- The bar supplies the labels; type only the expressions: >
---   WHERE     age >= 18 AND status = 'active'
---   ORDER BY  age DESC NULLS LAST, id ASC
--- <
--- Polars SQL supports `AND`/`OR`/`NOT`, `IS NULL`, `LIKE`/`ILIKE`, `IN`, and
--- `BETWEEN`. Quote columns with double quotes and strings with single quotes.
--- Names are case-sensitive and match the result; completion supplies them.
--- Repeated column names become `name`, `name_2`, etc. Full queries and subqueries
--- are not accepted. Invalid conditions preserve the previous view. `s`/`S`
--- place nulls last; ORDER BY expressions can specify NULLS FIRST or NULLS LAST.
--- Integers and booleans are typed. Numeric-looking strings remain strings;
--- use CAST(value AS DOUBLE) for numeric comparison/sorting of Redis strings.
--- Exact decimals, temporal values, and nested JSON remain text.
--- Explicit casts can enable numeric/temporal comparisons;
--- floating-point casts can lose precision. Nested JSON fields are not flattened.
---
--- Editing ~
--- `i` or <CR> stages a cell edit, `X` stages NULL, and `dd` stages deletion.
--- `u` undoes the last change; `U` discards all staged changes. `gs` or <C-s>
--- opens a review; <C-s> in that review applies the changes to the database.
--- SQL editing requires direct table-column mappings and a complete primary
--- or unique key in the result. Joined rows update their respective tables;
--- insertion is limited to single-table results. Read-only connections reject
--- edits. Transaction guarantees depend on the database adapter.
---
--- Exporting ~
--- Press `x` for the export dialog, or visual `x` for selected rows. Formats are
--- CSV, JSON, and SQL where supported. Exports use retained result rows, not a
--- fresh database query; a truncated result cannot export rows never fetched.
--- For a direct export: >vim
---   Sqmeow export csv /tmp/result.csv
---   Sqmeow export json clipboard
--- <
--- Dialect differences ~
--- Redis accepts one command per line; MongoDB accepts Extended JSON commands.
--- ScyllaDB/Cassandra use CQL and SurrealDB uses SurrealQL. SQL Server accepts
--- standalone GO batch separators, but not GO repetition or sqlcmd directives.
--- The destructive-query prompt is controlled by `query.confirm_destructive`;
--- use read-only database credentials when server-enforced restrictions matter.
---@tag sqmeow-queries
---@toc_entry Query and result workflow

--- The query log ~
---
--- `:Sqmeow log` reopens a prior result without executing its query again.
--- `query.history_size` controls how many query runs the engine keeps in memory.
--- With `query.persist_history = true`, logged results are also archived on disk
--- and can be restored after eviction or restart. `query.history_limit` controls
--- the displayed log length. `:Sqmeow log clear` removes the saved log/results.
---
--- Persistent files live under `core.path`, which defaults to
--- `stdpath('data') .. '/sqmeow'`:
---   bin/                 Installed engine binary.
---   connections.json     Saved connection definitions.
---   scratch/             Scratchpad files; write buffers normally with :write.
---   history/log.jsonl    Query log metadata.
---   history/results/    Archived result data.
---   session.json        Saved connection names and drawer expansion.
---
--- `ui.persist_session = true` saves the session on editor exit and reconnects
--- named connections once when the drawer next opens. Definitions must still
--- be available in the configured sources. It does not preserve live database
--- sessions, temporary tables, or in-memory databases. Project TOML lives in
--- `.sqmeow/`; scratchpads and history still use `core.path`.
---@tag sqmeow-history
---@toc_entry The query log

--- Auto-completion ~
---
--- sqmeow provides completion sources for both `blink.cmp` and `nvim-cmp`. The
--- completion engine uses the active connection to offer schemas, tables, views,
--- and columns as you type.
--- Columns are loaded on demand for relations in the current statement, including
--- multiline SELECT, WHERE, JOIN, GROUP BY, and ORDER BY clauses. Table aliases and
--- double-quoted, backtick-quoted, and bracket-quoted identifiers are supported.
--- Metadata comes from the active adapter; opening tables in the drawer is unnecessary.
--- Query context uses Neovim's built-in Tree-sitter API and the `sql` parser
--- (derekstride/tree-sitter-sql). Install it with `:TSInstall sql` using
--- nvim-treesitter. Without the parser, metadata and explicit `table.` column
--- completion remain available, but query-aware and alias completion require it.
---
--- To use with `blink.cmp`: >lua
---   require('blink.cmp').setup({
---     sources = {
---       default = { 'lsp', 'path', 'buffer', 'sqmeow' },
---       providers = {
---         sqmeow = {
---           name = 'Sqmeow',
---           module = 'sqmeow.completion.blink',
---         },
---       },
---     },
---   })
--- <
---
--- To use with `nvim-cmp`: >lua
---   require('cmp').setup({
---     sources = {
---       { name = 'sqmeow' },
---       -- ...
---     },
---   })
---   require('cmp').register_source('sqmeow', require('sqmeow.completion.cmp').new())
--- <
---@tag sqmeow-completion
---@toc_entry Auto-completion

--- Troubleshooting ~
---
--- Engine missing or incompatible:
---   Run `:Sqmeow health`, then `:Sqmeow install`. For a master checkout, build
---   with `:Sqmeow install cargo`. Use `:Sqmeow restart` after rebuilding.
--- Connection missing from the drawer:
---   Check `:pwd`, the nearest project config, and `sources` order. Duplicate
---   names keep the first entry. Inspect source errors with: >lua
---     local _, errors = require('sqmeow.api.connection').available()
---     vim.print(errors)
--- <
--- Query goes to the wrong database:
---   Check `:Sqmeow bind` before changing `:Sqmeow use`. A buffer pin takes
---   precedence over the active connection.
--- Result cannot be edited:
---   Include the table's complete primary/unique key and direct table columns.
---   Expressions and read-only connections cannot be edited as table cells.
--- Completion lacks aliases or query context:
---   Install the SQL Tree-sitter parser and open the target connection; see
---   |sqmeow-completion|.
--- Need more diagnostics:
---   Set `core.log_level = 'debug'`, restart the engine, reproduce the problem,
---   then run `:Sqmeow messages`. Restarting closes live connections.
---@tag sqmeow-troubleshooting
---@toc_entry Troubleshooting

local M = {}

--- The configuration the user passed, kept unmerged for `:checkhealth`.
---@type table|nil
M.user_config = nil

--- Configure the plugin. Optional; a partial table overrides only what it names.
---@param opts table|nil See |sqmeow-config|.
---@usage >lua
---   require('sqmeow').setup({
---     ui = { drawer = { width = 40 } },
---   })
--- <
function M.setup(opts)
  M.user_config = opts or {}

  local _, errors = require('sqmeow.config').apply(M.user_config)
  for _, err in ipairs(errors) do
    require('sqmeow.core.utils').notify(err, vim.log.levels.ERROR)
  end

  require('sqmeow.ui.highlights').setup()

  -- A colourscheme change wipes every group, including ours.
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('sqmeow.highlights', { clear = true }),
    desc = 'Redefine sqmeow highlight groups',
    callback = function()
      require('sqmeow.ui.highlights').setup()
    end,
  })

  local session = vim.api.nvim_create_augroup('sqmeow.session', { clear = true })
  if require('sqmeow.config').get().ui.persist_session then
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = session,
      desc = 'Save the open sqmeow connections',
      callback = function()
        require('sqmeow.server.session').save()
      end,
    })
  end

  -- A running engine holds the old settings, so tell it about the new ones.
  require('sqmeow.rpc.client').configure()
end

--- Install the engine binary. Nothing installs it automatically; call it from a build hook: >lua
---   {
---     '2giosangmitom/sqmeow.nvim',
---     dependencies = { 'MunifTanjim/nui.nvim' },
---     build = function()
---       require('sqmeow').install()
---     end,
---     opts = {},
---   }
--- <
--- Without a method it downloads a release, falling back to a cargo build. Methods are `'cargo'`,
--- `'curl'`, `'wget'` and `'powershell'`: >lua
---   require('sqmeow').install('cargo')
---   require('sqmeow').install('wget')
---   require('sqmeow').install({ version = '1.0.2' })
--- <
--- Blocks until done unless a `callback` is given.
---@param opts string|table|nil A method name, or a table of `method`, `version`, `callback` and
---  `timeout` in milliseconds.
---@return boolean|nil ok Whether an engine was installed, or nil when a `callback` was given.
---@return string|nil err
function M.install(opts)
  return require('sqmeow.server.install').install(opts)
end

--- Stop the engine. It restarts on the next call that needs it.
function M.stop()
  require('sqmeow.rpc.client').stop()
end

return M
