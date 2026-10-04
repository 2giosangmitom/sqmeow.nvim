<p align="center">
  <img src="https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif" alt="Cat typing at a keyboard" width="280">
</p>

<h1 align="center">sqmeow.nvim</h1>

<p align="center"><strong>Your database, right inside Neovim.</strong><br>Explore schemas, run queries, and edit results without leaving your editor.</p>

<p align="center">
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/2giosangmitom/sqmeow.nvim/ci.yml?branch=master&style=flat-square&label=ci" alt="ci status"></a>
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/releases/latest"><img src="https://img.shields.io/github/v/release/2giosangmitom/sqmeow.nvim?style=flat-square&label=release" alt="latest release"></a>
  <a href="https://github.com/2giosangmitom/sqmeow.nvim/blob/master/LICENSE"><img src="https://img.shields.io/github/license/2giosangmitom/sqmeow.nvim?style=flat-square&label=license" alt="license"></a>
  <a href="https://deepwiki.com/2giosangmitom/sqmeow.nvim"><img src="https://img.shields.io/badge/DeepWiki-Ask-blue?style=flat-square" alt="Ask DeepWiki"></a>
</p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#connections">Connections</a> ·
  <a href="#auto-completion">Completion</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#keymaps">Keymaps</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

---

## What you can do

- **🔎 Explore:** browse schemas, tables, views, routines, columns, types, and keys.
- **⚡ Query:** run the statement under your cursor, a selection, or an entire buffer. A Rust engine keeps Neovim responsive and pages large results.
- **✏️ Edit:** filter and sort results, change cells or rows, then review staged changes before applying them. Inspect query plans and errors in the result window.
- **🗂️ Pick up where you left off:** switch between connections and reopen scratchpads or previous results, even after restarting Neovim.
- **📤 Export:** save or copy CSV, JSON, and SQL `INSERT` statements, with optional batching and `CREATE TABLE`.
- **🔐 Keep secrets out of view:** mask passwords and load values with `{{ env "VAR" }}`, `{{ file "path" }}`, or `{{ exec "cmd" }}`.

Keymaps are buffer-local. Use the provided `<Plug>` mappings if you prefer your own shortcuts.

## Supported databases

PostgreSQL · CockroachDB · MySQL · MariaDB · SQLite · DuckDB · Redis · Valkey · Dragonfly · MongoDB · ScyllaDB · Cassandra · SurrealDB · ClickHouse · Oracle Database · Microsoft SQL Server

## Preview

![Overview](assets/overview.png)

<details>
<summary>More screenshots: in-grid editing and table structure</summary>

![In-grid editing](assets/inline-edit.png)

![Table structure](assets/table-structure.png)

</details>

## Installation

**You need:** Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim).

Choose your plugin manager below. Each example installs [nui.nvim](https://github.com/MunifTanjim/nui.nvim) and the sqmeow engine.

### lazy.nvim

With [lazy.nvim](https://github.com/folke/lazy.nvim), the build hook downloads the matching engine binary:

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

### mini.deps

Add this after setting up [mini.deps](https://nvim-mini.org/mini.nvim/readmes/mini-deps) in your `init.lua`. Its hooks install the engine after the plugin is installed or updated:

```lua
local install_engine = function()
  vim.schedule(function()
    require('sqmeow').install()
  end)
end

MiniDeps.add({
  source = '2giosangmitom/sqmeow.nvim',
  depends = { 'MunifTanjim/nui.nvim' },
  hooks = {
    post_install = install_engine,
    post_checkout = install_engine,
  },
})
```

`mini.deps` follows the default branch here. For unreleased commits, use `install('cargo')` in the hook to build the engine from source, or pin `checkout` to a release tag.

### vim.pack (Neovim 0.12+)

With Neovim's built-in [vim.pack](https://neovim.io/doc/user/pack.html#vim.pack), put this in your `init.lua`. The `PackChanged` handler installs the engine on initial install and after updates:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(event)
    local data = event.data
    if data.spec.name ~= 'sqmeow.nvim' or (data.kind ~= 'install' and data.kind ~= 'update') then
      return
    end

    vim.schedule(function()
      require('sqmeow').install()
    end)
  end,
})

vim.pack.add({
  'https://github.com/MunifTanjim/nui.nvim',
  {
    src = 'https://github.com/2giosangmitom/sqmeow.nvim',
    version = vim.version.range('>=0.0.0'), -- follow release tags
  },
})
```

Register the handler **before** `vim.pack.add()` so it catches the first install. Run `:packupdate` to update plugins.

> [!NOTE]
> Prebuilt engines ship for Linux (x86_64 and ARM64), Apple Silicon, and Windows x86_64. Other machines build from source automatically.
>
> To track `master` with lazy.nvim or vim.pack, remove the release version setting and build with `install('cargo')`. This requires a Rust toolchain and DuckDB.

Run `:checkhealth sqmeow` to verify your installation.

## Quick start

1. **Open** the schema drawer and result window with `:Sqmeow`.
2. **Add** a connection with `A` in the drawer, or run `:Sqmeow add`.
3. **Connect** with `<CR>`. Press `a` to create a scratchpad and `u` to use that connection for queries.
4. **Run** a query with `<CR>` on the statement under your cursor. In visual mode, `<CR>` runs the selection.

> [!TIP]
> Press `?` in the drawer or result window to see available keymaps. See `:h sqmeow-keymaps` for the complete reference.

### Dialect notes

- **SQL databases:** `<CR>` runs the statement under the cursor; `<leader>E` runs the whole buffer.
- **Redis:** enter one command per line. The drawer groups keys by type; Cluster and Sentinel URLs are supported (see below).
- **MongoDB:** enter commands as Extended JSON; use `use db_name` to switch databases.
- **ScyllaDB:** supports TLS and custom CA certificates through URL options.
- **SurrealDB:** use SurrealQL; namespaces, database selection, TLS, and custom CAs are supported. `.surql` scratchpads use the SurrealQL filetype.
- **Oracle Database:** supports Oracle URLs, TLS, privileged logins, TNS aliases, descriptors, and wallets. Cancelling a query returns immediately, but the next query waits for the server operation to finish.
- **Microsoft SQL Server:** connect with `mssql://` or `sqlserver://`; SQL authentication and TLS are supported. See below for SQL Server-specific details.

### Redis Cluster and Sentinel

Add a connection with `:Sqmeow add` using one of these URLs:

```text
redis+cluster://node1.example.com:6379,node2.example.com:6379
redis+sentinel://sentinel1.example.com:26379,sentinel2.example.com:26379/mymaster/0
```

Cluster URLs list reachable seed nodes; all nodes advertised by the cluster must also be reachable. Clusters use database 0 only. Sentinel URLs list Sentinel hosts, followed by the master service name (`mymaster`) and optional database number (default 0). The Redis master's advertised address must be reachable. Prefix the hosts with `user:password@` to authenticate to the Redis nodes/master (not to Sentinel). Use `rediss+cluster://` or `rediss+sentinel://` for TLS; percent-encode special characters in credentials.

### Microsoft SQL Server

Connect with `mssql://user:password@host:1433/database`. Leave the database empty to browse accessible databases. SQL authentication is supported. Windows/AD authentication and named-instance discovery are not currently available.

<details>
<summary>SQL Server details: TLS, batches, editing, and cancellation</summary>

- **TLS:** encryption is required and certificates are verified against system roots. For a private CA, set `sslrootcert=/path/ca.pem`. Through an SSH tunnel, set `hostname_in_certificate=db.example.com` if the certificate names the database host.
- **Self-signed certificates:** for a local server, explicitly set `trust_server_certificate=true` to disable certificate verification. `encrypt=false` encrypts only login traffic. Unknown options are rejected.
- **Batches:** T-SQL statements run in batches separated by a standalone `GO` line (optionally followed by a `--` comment). Semicolons stay within each batch, preserving variables and procedure definitions. `GO` repetition counts and sqlcmd directives are unsupported.
- **Results:** each row set is retained, including empty sets. Row limits cap retained rows while the rest of the response is drained so later batch statements can complete. For batches without row sets, the affected count comes from the last statement's `@@ROWCOUNT`.
- **Editing:** grid edits use transactions and require a complete primary or unique key. Identity and computed columns are generated by SQL Server. Inserts use `OUTPUT INSERTED.*`; SQL Server rejects this form on tables with enabled INSERT triggers.
- **Cancellation:** after a bounded Attention request, the session is discarded. The next request reconnects to the configured database; temporary tables, `USE`/`SET` state, and open transactions are lost. Failed requests are never replayed.
- **Read-only mode:** the engine checks statements rather than opening a read-only server session. Use a read-only database account for server-enforced restrictions.

</details>

## Connections

### SSH tunnels

sqmeow uses your system `ssh` command to forward a local port through an SSH host. If you already have a host in `~/.ssh/config`, enter its **Host alias** in the connection dialog's **SSH** field:

```sshconfig
Host hostname
  HostName yourip
  User user
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

1. Run `ssh hostname` in a terminal to verify that the SSH connection works.
2. Add a sqmeow connection with **SSH** set to `hostname` (not `yourip`). For PostgreSQL running on the SSH host, use `postgres://dbuser@localhost:5432/mydb` as the database URL.

Here, `localhost` is resolved **on the SSH host**, and `dbuser` is the database login, not the SSH login.

The equivalent saved connection is `{"name": "mydb", "url": "postgres://dbuser@localhost:5432/mydb", "ssh": "hostname"}`. If the database runs on another machine reachable from the SSH host, use that machine's hostname instead of `localhost` in the URL.

You can use `user@bastion` or `user@bastion:2222` in **SSH** without a config alias. OpenSSH still uses your keys, agent, and `~/.ssh/config`, including `ProxyCommand`. If a proxy needs credentials (for example, AWS SSO), authenticate before starting Neovim so `ssh` inherits the required environment.

### Project connections

Create `.sqmeow/connections.toml` in your project:

```toml
[dev_db]
type = "postgres"
host = "localhost"
port = 5432
database = "my_app_dev"
user = "dev_user"

[staging_db]
type = "mysql"
host = "staging.example.com"
port = 3306
database = "my_app_staging"
```

The nearest file is discovered from Neovim's current working directory upward whenever connections are loaded. Section names become connection names; fields match the connection dialog for that `type`.

- Ports are integers; `read_only`, `tls`, and `srv` are booleans.
- Optional `password` and `ssh` fields are supported, including password templates such as `password = '{{ env "PGPASSWORD" }}'`.
- SQLite and DuckDB use `path`, resolved relative to the project (or `:memory:`).

Project connections load before saved and environment connections by default. Duplicate names report a conflict and the first source wins. Edit project connections in the TOML file.

To disable discovery, configure `sources = { { type = 'file' }, { type = 'env' } }`. Reading TOML requires the matching engine binary.

Project files support `env` and `file` templates but reject `exec` directives. If an open connection's name matches a changed definition, disconnect it before reconnecting; its URL, read-only setting, and SSH host must match for reuse.

### Environment connections

Set `SQMEOW_CONNECTIONS` to a JSON array to load connections from the environment. Templates let you keep passwords out of the URL itself:

```sh
export SQMEOW_CONNECTIONS='[{"name": "dev", "url": "postgres://app:{{ env \"PGPASSWORD\" }}@localhost/dev"}]'
```

### Safety

> [!IMPORTANT]
> Use a read-only database account when you need permissions enforced by the server. Not every adapter can enforce read-only mode in the database session.

- Turn on **Read only** in the connection dialog or set `"read_only": true` in a connection (including `connections.json`). PostgreSQL, MySQL, ClickHouse, SQLite, and DuckDB enforce it in the database session. Redis, MongoDB, ScyllaDB, SurrealDB, and OracleDB use statement checks instead.
- sqmeow asks for confirmation before broad `DELETE`/`UPDATE`, `DROP`, `TRUNCATE`, or commands that empty Redis/MongoDB data. Set `query.confirm_destructive = false` to disable prompts.

## Auto-completion

sqmeow loads schema, table, view, and column suggestions on demand from the active adapter. Choose the setup for your completion engine below.

For query-aware column completion, install the `sql` Tree-sitter parser (`derekstride/tree-sitter-sql`), for example with `:TSInstall sql` through nvim-treesitter. This enables suggestions in `WHERE`, `GROUP BY`, `ORDER BY`, and multiline queries, including table aliases. Without it, schema, table, view, and explicit `table.` column completion still work.

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

## Commands

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
| `:Sqmeow use [name]`                                | Choose the connection to run queries against    |
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

## Keymaps

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

### Result window

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

### Filter bar

Press `gf` or `go` to open the filter bar above the grid.

- **SQL:** filters rerun the query as a subquery. `=` adds the selected cell's value to `WHERE`; `s` adds a sort expression to `ORDER BY`.
- **MongoDB:** uses filter and sort documents.
- **Redis, ScyllaDB, SurrealDB, and disconnected results:** filter in memory with `AND`/`OR`/`NOT`, `IS NULL`, `LIKE`/`ILIKE`, `IN`, and `BETWEEN`.

| Key               | Action                       |
| ----------------- | ---------------------------- |
| `<CR>`            | Run query with bar's content |
| `q`, `<Esc>`      | Close bar without filtering  |
| `<C-p>` / `<C-n>` | Older / newer filter         |
| `<C-x><C-o>`      | Complete column name         |

### Editing results

You can edit a result when a column maps directly to a table column and the result includes the table's complete primary or unique key.

Joined rows update each table by its own key. Deleting a row affects the table of its first editable column. Adding rows is limited to single-table results.

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

## Configuration

Calling `setup()` is optional. This is the default configuration; override only the settings you need:

```lua
require('sqmeow').setup({
  sources = { { type = 'project' }, { type = 'file' }, { type = 'env' } }, -- connection sources
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

## Contributing

Want to help? Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, local checks, and pull request guidance. If you use AI coding tools, **review and test the changes locally** before submitting them.

## License

[MIT](LICENSE). Thanks to everyone who has contributed.

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)

## Acknowledgments

Inspired by [vim-dadbod](https://github.com/tpope/vim-dadbod), [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), and [nvim-dbee](https://github.com/kndndrj/nvim-dbee).
