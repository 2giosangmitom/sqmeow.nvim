# sqmeow.nvim

![Cat typing at a keyboard](https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif)

A lightweight database client that lives inside Neovim. Browse databases, run queries, edit data, and explore results without leaving your editor.

If you spend most of your time in the terminal and don't want to switch to a GUI just to inspect a few rows, sqmeow.nvim is for you.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/2giosangmitom/sqmeow.nvim)

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

## Features

- **Multiple databases:** Work with SQL, NoSQL, and analytical databases in one place.
- **Interactive results:** Browse, filter, sort, and edit data directly in Neovim.
- **Query history:** Revisit previous results without running queries again.
- **Fast result processing:** Filter and sort retained rows locally using Polars.
- **Project-local connections:** Keep connections and scratchpads alongside your project.
- **Completion:** Database-aware suggestions with blink.cmp or nvim-cmp.
- **Rust engine:** Database operations run in a separate Rust process.

## Supported databases

- **Relational & analytical:** PostgreSQL, CockroachDB, MySQL, MariaDB, SQLite, DuckDB, ClickHouse, Oracle Database, Microsoft SQL Server.
- **Key-value & document:** Redis, Valkey, Dragonfly, MongoDB, SurrealDB.
- **Wide-column:** ScyllaDB, Cassandra.

## Installation

Requires Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim).

Calling `setup()` is optional unless you want to customize the defaults.

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

This tracks the default branch and builds the engine from source. To use a release instead, set `checkout` to a release tag and call `install()` in the hook.

</details>

<details>
<summary>vim.pack (Neovim 0.12+)</summary>

Register the handler before `vim.pack.add()`:

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

Run `:packupdate` to update your plugins.

</details>

The install hook downloads the matching engine release. Prebuilt binaries are available for Linux (x86_64/ARM64), macOS (Apple Silicon), and Windows (x86_64).

Building from source requires Rust, SQLite, and DuckDB. See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions.

To track `master` with lazy.nvim or vim.pack, remove the release version setting and use `install("cargo")`.

After installation, run `:checkhealth sqmeow` to verify your setup. Use `:Sqmeow restart` after rebuilding the engine.

## Getting started

1. Run `:Sqmeow` to open the drawer and results window.
2. Press `A` in the drawer to add a database connection.
3. Press `<CR>` to connect, then `u` to select it for queries.
4. Press `a` to create a scratchpad, write a query, and press `<CR>` to execute it.

Use visual `<CR>` to execute selected text, or `<leader>E` to execute the entire buffer.

Press `?` in the drawer or results window to see available keymaps.

### Keymaps

| Key         | Action                                                |
| ----------- | ----------------------------------------------------- |
| `p` / `P`   | Preview a table / also open its query                 |
| `gR`        | Follow foreign keys from a table or result column     |
| `L` / `H`   | Next / previous page                                  |
| `K`         | Show row details                                      |
| `gf` / `go` | Open the filter / sort bar                            |
| `=`         | Filter by the current cell                            |
| `s` / `S`   | Sort by column / add another sort column              |
| `i`         | Stage a cell edit                                     |
| `gs`        | Review staged edits                                   |
| `<C-s>`     | Apply edits from the review window                    |
| `x`         | Export results as CSV, JSON, or SQL (where supported) |
| `R`         | Reset filters, sorting, and hidden columns            |

### Working with results

**Editing**

Edit cells directly in the result grid, review your changes, and apply them when ready.

Editing requires table-backed columns and a complete primary or unique key. Availability varies by database adapter. For server-enforced read-only access, use a read-only database account.

**Filtering and sorting**

sqmeow.nvim uses Polars SQL to filter and sort retained results locally, including results from query history.

You can explore data without rerunning the original query or losing staged edits. Rerun the query whenever you need fresh data.

**Query languages**

Each database uses its own query language:

- SQL databases use their respective SQL dialects.
- Redis accepts one command per line.
- MongoDB accepts Extended JSON commands.
- ScyllaDB and Cassandra use CQL.
- SurrealDB uses SurrealQL.

For more details, see `:h sqmeow-commands`, `:h sqmeow-keymaps`, and `:h sqmeow-queries`.

## Connections

Add and save connections through the drawer, or define project-specific connections in `.sqmeow/connections.toml`:

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

The nearest project configuration overrides saved connections with the same name. Relative database paths are resolved from the project root.

### Credentials

You can also connect using a database URL:

```toml
[dev]
url = "{{ env 'DATABASE_URL' }}"
read_only = true
```

Set `DATABASE_URL` in your environment or in a `.env` file next to `.sqmeow/`. Environment variables take precedence over values in `.env`.

Keep `.env` out of version control, and reconnect after changing credentials.

**SSH tunnels**

To connect through SSH, set `ssh = "user@bastion"` or use a Host alias from `~/.ssh/config`. The database host is resolved from the SSH host.

See `:h sqmeow-project` and `:h sqmeow-credentials` for all connection options.

### Scratchpads

Store project queries in `.sqmeow/scratchpads/` using `.sql`, `.redis`, `.json`, or `.surql` files.

Manage them directly from the drawer:

- `a`: Create a file or folder.
- `R`: Rename or move.
- `d`: Delete.

Queries run against the currently selected connection.

## Completion

sqmeow.nvim integrates with [blink.cmp](https://github.com/Saghen/blink.cmp) and [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) to provide database-aware completion.

For query-aware column and alias suggestions, install the SQL Tree-sitter parser (for example, with `:TSInstall sql` via nvim-treesitter).

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

See `:h sqmeow-completion` for more details.

## Configuration

You can customize behavior with `setup()`.

Common options with their defaults:

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

`max_rows` limits the number of retained rows, while `page_size` controls how many rows appear per page.

Set `max_rows = 0` for unlimited rows or `timeout_ms = 0` to disable query deadlines.

See `:h sqmeow-config` for all configuration options and `:h sqmeow-keymaps` for custom keymaps.

## Acknowledgments

Thanks to these projects for ideas and workflows:

- [vim-dadbod](https://github.com/tpope/vim-dadbod)
- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)
- [nvim-dbee](https://github.com/kndndrj/nvim-dbee)
- [squix](https://github.com/eduardofuncao/squix)
- [DBeaver](https://github.com/dbeaver/dbeaver)

I've borrowed plenty of ideas and even some code here and there. That's the beauty of open source! :)

## Contributing

Contributions welcome. Open an issue, report a bug, suggest a feature, or submit a pull request.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

Thanks to everyone who has contributed to sqmeow.nvim! 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)
