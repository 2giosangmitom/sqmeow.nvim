<h1 align="center">🐱 sqmeow.nvim</h1>

<p align="center">Explore schemas, run queries, and edit results from Neovim — with a responsive Rust engine and keyboard-driven workflow.</p>

<p align="center">
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/2giosangmitom/sqmeow.nvim/ci.yml?branch=master&style=flat-square&label=ci" alt="ci status"></a>
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/releases/latest"><img src="https://img.shields.io/github/v/release/2giosangmitom/sqmeow.nvim?style=flat-square&label=release" alt="latest release"></a>
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/blob/master/LICENSE"><img src="https://img.shields.io/github/license/2giosangmitom/sqmeow.nvim?style=flat-square&label=license" alt="license"></a>
  <a href="https://deepwiki.com/2giosangmitom/sqmeow.nvim"><img src="https://img.shields.io/badge/DeepWiki-Ask-blue?style=flat-square" alt="Ask DeepWiki"></a>
</p>

<p align="center">
  <a href="#-features">Features</a> •
  <a href="#%EF%B8%8F-supported-databases">Databases</a> •
  <a href="#-installation">Installation</a> •
  <a href="#-quick-start">Quick Start</a> •
  <a href="#%EF%B8%8F-configuration">Configuration</a> •
  <a href="#-contributing">Contributing</a>
</p>

---

## ✨ Features

- **⚡ Responsive queries** — the Rust engine runs outside Neovim's UI thread and pages large results.
- **🐘 Multiple connections** — connect to several databases and switch between them from the drawer.
- **🌲 Schema browser** — inspect schemas, tables, views, routines, columns, types, and keys.
- **📄 Query scratchpads** — keep query buffers between sessions and associate them with a connection.
- **✏️ Editable results** — change cells, insert or delete rows, review staged changes, and apply them.
- **🔎 Filtering and sorting** — run `WHERE` / `ORDER BY` on supported databases or filter held results in memory.
- **▶️ Flexible execution** — run the statement under the cursor, a visual selection, or the whole buffer.
- **🧭 Query plans and errors** — inspect `EXPLAIN` output and database errors in the result window.
- **🕘 Query history** — reopen previous results, including after restarting Neovim.
- **📤 Export** — save or copy CSV, JSON, or SQL `INSERT` statements, with optional batching and `CREATE TABLE`.
- **🔐 Secret-friendly URLs** — mask passwords and load values with `{{ env "VAR" }}`, `{{ file "path" }}`, or `{{ exec "cmd" }}`.
- **⌨️ Local keymaps** — mappings stay buffer-local; `<Plug>` mappings are available for your own shortcuts.

## 🗄️ Supported Databases

PostgreSQL, CockroachDB, MySQL, MariaDB, SQLite, DuckDB, Redis, Valkey, Dragonfly, MongoDB, ScyllaDB, Cassandra, SurrealDB, ClickHouse, Oracle Database, and Microsoft SQL Server.

## 👀 Preview

![Overview](assets/overview.png)

### ✏️ In-grid editing

![In-grid editing](./assets/inline-edit.png)

### 🔍 Table structure

![Table structure](./assets/table-structure.png)

## 🚀 Installation

**Requirements:** Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim). The build hook below downloads the matching engine binary.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "2giosangmitom/sqmeow.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  version = "*",
  build = function()
    -- Downloads the matching release binary. Pass 'curl', 'wget', 'powershell', or 'cargo' to choose a method.
    require("sqmeow").install()
  end,
  opts = {},
  cmd = "Sqmeow",
  keys = {
    { "<leader>Dd", "<cmd>Sqmeow toggle<cr>", desc = "Toggle" },
    { "<leader>Dc", "<cmd>Sqmeow cancel<cr>", desc = "Cancel" },
    { "<leader>Da", "<cmd>Sqmeow add<cr>", desc = "Add Connection" },
    { "<leader>Ds", "<cmd>Sqmeow scratch<cr>", desc = "New Scratchpad" },
  },
}
```

> [!NOTE]
> To track `master`, remove `version` and build with `install('cargo')` (requires a Rust toolchain and DuckDB). Run `:checkhealth sqmeow` to verify the installation.

## ⚡ Quick Start

1. Run `:Sqmeow` to open the schema drawer and result window.
2. Press `A` in the drawer (or run `:Sqmeow add`) and enter a connection.
3. Press `<CR>` on the connection to connect. Press `a` to create a scratchpad and `u` to use that connection for queries.
4. Write a query, then press `<CR>` to run the statement under the cursor. In visual mode, `<CR>` runs the selection.

> [!TIP]
> Press `?` in the drawer or result window to see available keymaps. See `:h sqmeow-keymaps` for the complete reference.

### Dialect Notes

- **SQL databases** — `<CR>` runs the statement under the cursor; `<leader>E` runs the whole buffer.
- **Redis** — enter one command per line. The drawer groups keys by type; cluster and Sentinel URLs are supported.
- **MongoDB** — enter commands as Extended JSON; use `use db_name` to switch databases.
- **ScyllaDB** — supports TLS and custom CA certificates through URL options.
- **SurrealDB** — use SurrealQL; namespaces, database selection, TLS, and custom CAs are supported. `.surql` scratchpads use the SurrealQL filetype.
- **Oracle Database** — supports Oracle URLs, TLS, privileged logins, TNS aliases, descriptors, and wallets. Cancelling a query returns immediately, but the next query waits for the server operation to finish.
- **Microsoft SQL Server** — connect with `mssql://` or `sqlserver://`; SQL authentication and TLS are supported. See below for SQL Server-specific details.

### Microsoft SQL Server

Connect with `mssql://user:password@host:1433/database`. Leave the database empty to browse accessible databases. SQL authentication is supported; Windows/AD authentication and named-instance discovery are not currently available.

- **TLS:** encryption is required and certificates are verified against system roots. For a private CA, set `sslrootcert=/path/ca.pem`. Through an SSH tunnel, set `hostname_in_certificate=db.example.com` if the certificate names the database host.
- **Self-signed certificates:** for a local server, explicitly set `trust_server_certificate=true` to disable certificate verification. `encrypt=false` encrypts only login traffic. Unknown options are rejected.
- **Batches:** T-SQL statements run in batches separated by a standalone `GO` line (optionally followed by a `--` comment). Semicolons stay within each batch, preserving variables and procedure definitions. `GO` repetition counts and sqlcmd directives are unsupported.
- **Results:** each row set is retained, including empty sets. Row limits cap retained rows while the rest of the response is drained so later batch statements can complete. For batches without row sets, the affected count comes from the last statement's `@@ROWCOUNT`.
- **Editing:** grid edits use transactions and require a complete primary or unique key. Identity and computed columns are generated by SQL Server. Inserts use `OUTPUT INSERTED.*`; SQL Server rejects this form on tables with enabled INSERT triggers.
- **Cancellation:** after a bounded Attention request, the session is discarded. The next request reconnects to the configured database; temporary tables, `USE`/`SET` state, and open transactions are lost. Failed requests are never replayed.
- **Read-only mode:** the engine checks statements rather than opening a read-only server session. Use a read-only database account for server-enforced restrictions.

### SSH Tunnels

sqmeow uses your system `ssh` command to forward a local port through an SSH host. If you already have a host in `~/.ssh/config`, enter its **Host alias** in the connection dialog's **SSH** field:

```sshconfig
Host hostname
  HostName yourip
  User user
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

1. Run `ssh hostname` in a terminal to verify that the SSH connection works.
2. Add a sqmeow connection with **SSH** set to `hostname` (not `yourip`). For PostgreSQL running on the SSH host, use `postgres://dbuser@localhost:5432/mydb` as the database URL. `localhost` is resolved **on the SSH host**; `dbuser` is the database login, not the SSH login.

The equivalent saved connection is `{"name": "mydb", "url": "postgres://dbuser@localhost:5432/mydb", "ssh": "hostname"}`. If the database runs on another machine reachable from the SSH host, use that machine's hostname instead of `localhost` in the URL.

You can use `user@bastion` or `user@bastion:2222` in **SSH** without a config alias. OpenSSH still uses your keys, agent, and `~/.ssh/config`, including `ProxyCommand`. If a proxy needs credentials (for example, AWS SSO), authenticate before starting Neovim so `ssh` inherits the required environment.

### Environment Connections

Set `SQMEOW_CONNECTIONS` to a JSON array to load connections from the environment. Templates let you keep passwords out of the URL itself:

```sh
export SQMEOW_CONNECTIONS='[{"name": "dev", "url": "postgres://app:{{ env \"PGPASSWORD\" }}@localhost/dev"}]'
```

### Safety

- Enable **Read only** in the connection dialog or set `"read_only": true` in a connection (including `connections.json`) to restrict it to read statements. PostgreSQL, MySQL, ClickHouse, SQLite, and DuckDB enforce read-only access in the database session. Redis, MongoDB, ScyllaDB, SurrealDB, and OracleDB use statement checks instead; use a read-only database account whenever server-enforced permissions matter.
- sqmeow asks for confirmation before broad `DELETE`/`UPDATE`, `DROP`, `TRUNCATE`, or commands that empty Redis/MongoDB data. Disable prompts with `query.confirm_destructive = false`.

## 🤖 Auto-completion

sqmeow provides database metadata auto-completion (schemas, tables, views, and columns) that integrates with your completion engine. Metadata is loaded on demand from the active adapter.

Query-aware column completion uses Neovim's built-in Tree-sitter API. Install the `sql` parser (`derekstride/tree-sitter-sql`), for example with `:TSInstall sql` through nvim-treesitter. This enables columns from the current statement in `WHERE`, `GROUP BY`, `ORDER BY`, and multiline queries, including table aliases. Without the parser, schemas, tables, views, and explicit `table.` column completion remain available.

### blink.cmp

To enable completion in [blink.cmp](https://github.com/saghen/blink.cmp), add the `sqmeow` source provider to your configuration:

```lua
require('blink.cmp').setup({
  sources = {
    default = { 'lsp', 'path', 'buffer', 'sqmeow' },
    providers = {
      sqmeow = {
        name = 'Sqmeow',
        module = 'sqmeow.completion.blink',
      },
    },
  },
})
```

### nvim-cmp

To enable completion in [nvim-cmp](https://github.com/hrsh7th/nvim-cmp), register the custom source and add it to your sources list:

```lua
local cmp = require('cmp')
cmp.setup({
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
    { name = 'sqmeow' },
    -- ...
  }),
})

-- Register the source
cmp.register_source('sqmeow', require('sqmeow.completion.cmp').new())
```

## ⌨️ Commands

| Command                                             | Description                                     |
| --------------------------------------------------- | ----------------------------------------------- |
| `:Sqmeow`                                           | Open drawer and result window                   |
| `:Sqmeow toggle`                                    | Show or hide schema drawer                      |
| `:Sqmeow drawer`                                    | Show schema drawer                              |
| `:Sqmeow open` / `close`                            | Show / hide result window                       |
| `:Sqmeow add`                                       | Add a connection                                |
| `:Sqmeow save`                                      | Save connection for next time                   |
| `:Sqmeow edit [name]`                               | Edit a saved connection                         |
| `:Sqmeow remove <name>`                             | Delete a saved connection                       |
| `:Sqmeow use [name]`                                | Choose the connection to run queries against     |
| `:Sqmeow bind <name\|none>`                         | Tie current buffer to a connection, or untie it |
| `:Sqmeow disconnect`                                | Close current connection                        |
| `:Sqmeow scratch [name]`                            | Create a scratchpad                             |
| `:Sqmeow execute [sql]`                             | Run buffer, selection, or given SQL             |
| `:Sqmeow statement`                                 | Run statement under cursor                      |
| `:Sqmeow cancel`                                    | Stop running query                              |
| `:Sqmeow next` / `prev`                             | Next / previous page                            |
| `:Sqmeow float`                                     | Move result between split and float             |
| `:Sqmeow review`                                    | Review and apply staged edits                   |
| `:Sqmeow export <csv\|json\|sql> [path\|clipboard]` | Export result to file or clipboard              |
| `:Sqmeow log [clear]`                               | Reopen past result, or clear log                |
| `:Sqmeow install [method]`                          | Install engine binary                           |
| `:Sqmeow start` / `stop` / `restart`                | Start, stop or restart engine                   |
| `:Sqmeow messages`                                  | Show engine log                                 |
| `:Sqmeow health`                                    | Run health check                                |

## 🗺️ Keymaps

### Drawer

| Key         | Action                                     |
| ----------- | ------------------------------------------ |
| `<CR>`, `o` | Expand or collapse node                    |
| `u`         | Run queries against this connection        |
| `p`         | Preview relation's first page              |
| `K`         | Show table's or key's structure            |
| `f`         | Show only Redis keys matching a glob       |
| `r`         | Reload subtree                             |
| `y` / `s`   | Yank qualified name / a `SELECT`           |
| `a`         | Create a scratchpad                        |
| `A` / `e`   | Add / edit a connection                    |
| `R`         | Rename connection or scratchpad            |
| `d`         | Delete connection/scratchpad, or clear log |
| `?` / `q`   | Show keymaps / close drawer                |

### Result Window

| Key         | Action                                  |
| ----------- | --------------------------------------- |
| `L` / `H`   | Next / previous page                    |
| `]H` / `[H` | Last / first page                       |
| `K`         | Show row's details                      |
| `gK`        | Show table's columns and indexes        |
| `]r` / `[r` | Next / previous statement's result      |
| `x`         | Export result, or selected rows         |
| `gf` / `go` | Open filter bar on `WHERE` / `ORDER BY` |
| `=`         | Filter by cell's value                  |
| `s` / `S`   | Sort by column / add to sort            |
| `-` / `g-`  | Hide column / show hidden columns       |
| `R`         | Clear filters, sort and hidden columns  |
| `Z`         | Move between split and float            |
| `?` / `q`   | Show keymaps / close result window      |

### Filter Bar

Press `gf` or `go` to open the filter bar above the grid. On SQL databases, filters rerun the query as a subquery; `=` adds the selected cell's value to `WHERE`, and `s` adds a sort expression to `ORDER BY`. MongoDB uses filter and sort documents. Redis, ScyllaDB, SurrealDB, and disconnected results are filtered in memory with `AND`/`OR`/`NOT`, `IS NULL`, `LIKE`/`ILIKE`, `IN`, and `BETWEEN`.

| Key               | Action                       |
| ----------------- | ---------------------------- |
| `<CR>`            | Run query with bar's content |
| `q`, `<Esc>`      | Close bar without filtering  |
| `<C-p>` / `<C-n>` | Older / newer filter         |
| `<C-x><C-o>`      | Complete column name         |

### Editing Results

Editing is available when a result column maps directly to a table column and the result includes that table's complete primary or unique key. Joined rows update each table by its own key. Deleting a row affects the table associated with its first editable column; adding rows is limited to single-table results.

| Key           | Action                                           |
| ------------- | ------------------------------------------------ |
| `i`, `<CR>`   | Edit cell                                        |
| `X`           | Set cell to `NULL`                               |
| `g=`          | Set cell to SQL expression, e.g. `now()`         |
| `o` / `D`     | Add row / copy row without primary key           |
| `dd` / `d`    | Delete row / selected rows                       |
| `u` / `U`     | Undo last change / discard all                   |
| `gs`, `<C-s>` | Review staged changes; `<C-s>` in review applies |
| `<C-c>`       | Stop changes being applied, or a running query   |

### Scratchpad

| Key             | Action                     |
| --------------- | -------------------------- |
| `<CR>`          | Run statement under cursor |
| `<CR>` (visual) | Run selection              |
| `<leader>E`     | Run whole buffer           |
| `<C-c>`         | Stop running query         |

## ⚙️ Configuration

Calling `setup()` is optional. This is the default configuration; override only the settings you need:

```lua
require('sqmeow').setup({
  sources = { { type = 'file' }, { type = 'env' } }, -- connection sources
  core = {
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'), -- engine, saved connections, scratchpads, and history
    log_level = 'warn',
  },
  ui = {
    drawer = { width = 36 },
    result = { height = 16, page_size = 100, max_column_width = 48, column_icons = true, null_text = 'NULL' },
    border = 'default', -- 'default' follows 'winborder'; or a nui style such as 'rounded'
    winbar = true,
    persist_session = false, -- reopen last session's connections and drawer nodes
  },
  query = {
    max_rows = 100000,
    timeout_ms = 0, -- 0 disables timeout
    history_size = 32, -- result runs kept in memory
    persist_history = true, -- also save the log and results to disk
    history_limit = 500,
    confirm_destructive = true, -- ask before destructive statements
  },
  icons = {}, -- Nerd Font glyphs; recolour via SqmeowIcon* highlight groups
  keymaps = {},
  redact_urls = true, -- mask passwords wherever a URL is shown
})
```

See `:h sqmeow-config` for descriptions of every option.

## 🤝 Contributing

The toolchain is pinned with [mise](https://mise.jdx.dev); development tasks are [just](https://just.systems) recipes:

```sh
mise install   # Install Rust, just, stylua, selene, and lua-language-server
just db-up     # Start integration-test databases in Docker
just           # Run lint, tests, and the help-file check (same checks as CI)
just docs      # Regenerate doc/sqmeow.txt
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org).

## 📜 License

[MIT](LICENSE). Thanks to everyone who has contributed 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)

## 🎖️ Acknowledgments

Inspired by [vim-dadbod](https://github.com/tpope/vim-dadbod), [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), and [nvim-dbee](https://github.com/kndndrj/nvim-dbee).
