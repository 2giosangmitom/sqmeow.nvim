# sqmeow.nvim

![Cat typing at a keyboard](https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif)

A database client for Neovim. Browse schemas, run queries, edit rows, and export results.

Queries run in a separate Rust engine. Results stay available for filtering, sorting, and reopening from history.

## Preview

<details open>
<summary>Screenshots</summary>

### Overview

![Overview](assets/overview.png)

### Editing results

![In-grid editing](assets/inline-edit.png)

### Table structure

![Table structure](assets/table-structure.png)

</details>

## Supported databases

- **Relational & analytical**: PostgreSQL, CockroachDB, MySQL, MariaDB, SQLite, DuckDB, ClickHouse, Oracle Database, Microsoft SQL Server.
- **Key-value & document**: Redis, Valkey, Dragonfly, MongoDB, SurrealDB.
- **Wide-column**: ScyllaDB, Cassandra.

## Installation

Requires Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim). `setup()` is optional unless you want to change the defaults.

<details open>
<summary>lazy.nvim</summary>

```lua
{
  "2giosangmitom/sqmeow.nvim",
  version = "*",
  dependencies = { "MunifTanjim/nui.nvim" },
  build = function()
    require("sqmeow").install()
  end,
  opts = {},
  cmd = "Sqmeow",
}
```

</details>

<details>
<summary>mini.deps</summary>

Add this after setting up `mini.deps`:

```lua
local install_engine = function()
  vim.schedule(function()
    require("sqmeow").install("cargo")
  end)
end

MiniDeps.add({
  source = "2giosangmitom/sqmeow.nvim",
  depends = { "MunifTanjim/nui.nvim" },
  hooks = {
    post_install = install_engine,
    post_checkout = install_engine,
  },
})
```

This follows the default branch and builds the engine from source. To use a release, set `checkout` to a release tag and use `install()` in the hook.

</details>

<details>
<summary>vim.pack (Neovim 0.12+)</summary>

Register the handler before `vim.pack.add()` so it catches the first install:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(event)
    local data = event.data
    if data.spec.name ~= "sqmeow.nvim" or (data.kind ~= "install" and data.kind ~= "update") then
      return
    end

    vim.schedule(function()
      require("sqmeow").install()
    end)
  end,
})

vim.pack.add({
  "https://github.com/MunifTanjim/nui.nvim",
  {
    src = "https://github.com/2giosangmitom/sqmeow.nvim",
    version = vim.version.range(">=0.0.0"),
  },
})
```

Run `:packupdate` to update plugins.

</details>

The install hook downloads the matching engine release. Prebuilt binaries are available for Linux x86_64/ARM64, Apple Silicon, and Windows x86_64. Building from source requires Rust and DuckDB; see [CONTRIBUTING.md](CONTRIBUTING.md) for the toolchain.

To follow `master` with lazy.nvim or vim.pack, remove the release version setting and use `install("cargo")`. Run `:checkhealth sqmeow` after installation and `:Sqmeow restart` after rebuilding the engine.

## Usage

1. Run `:Sqmeow` to open the drawer and result window.
2. Press `A` in the drawer to add a connection.
3. Press `<CR>` on the connection to open it, then `u` to select it for queries.
4. Press `a` to create a scratchpad. Write a query and press `<CR>` to run it.

Visual `<CR>` runs the selection; `<leader>E` runs the whole buffer. Press `?` in the drawer or result window for its keymaps.

In the drawer, `p` previews a table's rows and `P` also opens the preview query in an editor.

Press `gR` on a drawer table or result column to browse foreign keys under `Belongs to` and
`Referenced by`. Each constraint shows its columns in order, including composite keys and
self-references. `<CR>` follows a relationship to the other table; `K` opens its structure.
Configure these keys under `keymaps.relationships`. The browser reads declared foreign keys;
it does not fetch related rows or infer cardinality or many-to-many relationships.
Inspired by [Squix](https://github.com/eduardofuncao/squix). See `:h sqmeow-relationships`.

| Result key     | Action                                           |
| -------------- | ------------------------------------------------ |
| `L` / `H`      | Next / previous page                             |
| `K`            | Row details                                      |
| `gf` / `go`    | Filter / sort bar                                |
| `=`            | Filter by the current cell                       |
| `s` / `S`      | Sort by column / add another sort column         |
| `i`            | Stage a cell edit                                |
| `gs` / `<C-s>` | Review edits; `<C-s>` in the review applies them |
| `x`            | Export CSV, JSON, or SQL where supported         |
| `R`            | Clear filters, sorting, and hidden columns       |

Editing requires columns that map to a table and a complete primary or unique key. Editing support varies by adapter. Use a read-only database account when you need server-enforced permissions.

SQL databases use their own query dialects. Redis accepts one command per line, MongoDB accepts Extended JSON commands, ScyllaDB/Cassandra use CQL, and SurrealDB uses SurrealQL.

See `:h sqmeow-commands`, `:h sqmeow-keymaps`, and `:h sqmeow-queries` for the full reference.

### Filtering results

Every adapter uses Polars SQL to filter and sort retained rows, including disconnected and historical results. Filtering preserves staged edits and does not rerun the database query.

Press `gf` or `go`. Type only the expressions; the bar supplies the labels:

```text
WHERE     age >= 18 AND status = 'active'
ORDER BY  age DESC NULLS LAST, id ASC
```

Column names are case-sensitive. Use double quotes for names such as `"Customer Name"` and single quotes for strings. Numeric-looking strings remain strings; use `CAST(value AS DOUBLE)` for numeric comparisons when needed.

Filters cover all retained pages but cannot recover rows omitted by the query or `query.max_rows`. Run the query again for fresh data. See `:h sqmeow-queries` for supported expressions and type handling.

## Connections

Add and save connections through the drawer, or define them per project in `.sqmeow/connections.toml`:

```toml
[dev]
type = "postgres"
host = "localhost"
port = 5432
database = "my_app"
user = "dev_user"
password = "{{ env 'PGPASSWORD' }}"

[local]
type = "sqlite"
path = "app.db"
```

The nearest project file is loaded from the working directory upward. Project definitions take precedence over saved connections with the same name. Relative database paths resolve from the project root.

### Credentials

A connection can use a complete URL:

```toml
[dev]
url = "{{ env 'DATABASE_URL' }}"
read_only = true
```

Put `DATABASE_URL` in the process environment or in `.env` beside `.sqmeow/`:

```dotenv
DATABASE_URL=postgres://dev_user:local-password@localhost:5432/my_app
```

Process variables take precedence. Reconnect after changing `.env`, and keep it out of version control. URL entries can set `read_only` and `ssh`, but cannot mix `url` with `type`, `host`, or other connection fields.

For SSH tunnels, set `ssh = "user@bastion"` or use a Host alias from `~/.ssh/config`. The database host is resolved from the SSH host.

See `:h sqmeow-project` and `:h sqmeow-credentials` for connection fields, templates, and SSH options.

### Scratchpads

Keep project queries under `.sqmeow/scratchpads/`:

```text
.sqmeow/scratchpads/
├── users.sql
└── reports/
    └── monthly.sql
```

Expand `scratchpads` → `local scratchpads` in the drawer. Use `a` to create files or folders, `R` to rename or move them, and `d` to delete them. Scratchpads use the selected connection; folders do not bind them to a database.

Supported extensions are `.sql`, `.redis`, `.json`, and `.surql`. For development, the repo includes [adapter smoke-test scratchpads](.sqmeow/scratchpads/README.md).

## Completion

Completion is available for `blink.cmp` and `nvim-cmp`. Install the `sql` Tree-sitter parser for query-aware column and alias completion, for example with `:TSInstall sql` through nvim-treesitter.

<details>
<summary>blink.cmp</summary>

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "buffer", "sqmeow" },
    providers = {
      sqmeow = {
        name = "Sqmeow",
        module = "sqmeow.completion.blink",
      },
    },
  },
})
```

</details>

<details>
<summary>nvim-cmp</summary>

```lua
local cmp = require("cmp")
cmp.register_source("sqmeow", require("sqmeow.completion.cmp").new())

cmp.setup({
  sources = cmp.config.sources({
    { name = "nvim_lsp" },
    { name = "sqmeow" },
  }),
})
```

</details>

See `:h sqmeow-completion` for details.

## Configuration

Common options, shown with their defaults:

```lua
require("sqmeow").setup({
  ui = {
    drawer = { position = "left", width = 36 },
    result = { height = 16, page_size = 100, max_column_width = 48 },
    persist_session = false,
  },
  query = {
    max_rows = 100000,
    timeout_ms = 0,
    persist_history = true,
    confirm_destructive = true,
  },
  redact_urls = true,
})
```

`max_rows` limits retained rows; `page_size` sets displayed rows per page. A zero row limit is unlimited, and a zero timeout disables cancellation by deadline.

See `:h sqmeow-config` for all options and `:h sqmeow-keymaps` to change mappings.

## Acknowledgments

Thanks to these projects for database workflow ideas:

- [vim-dadbod](https://github.com/tpope/vim-dadbod)
- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)
- [nvim-dbee](https://github.com/kndndrj/nvim-dbee)
- [squix](https://github.com/eduardofuncao/squix)

I borrowed lots of ideas and even some code here and there. That's the beauty of the open-source world :)

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and checks.

Thanks to all the [contributors](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors) 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)
