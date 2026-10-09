# sqmeow.nvim

![Cat typing at a keyboard](https://media.giphy.com/media/JIX9t2j0ZTN9S/giphy.gif)

A database client for Neovim. If you live in the terminal and hate switching to a GUI or browser tab just to check a row, this is for you: browse schemas in a sidebar drawer, write queries in scratchpads, edit rows right in the result grid, and export to CSV, JSON, or SQL.

Queries run in a separate Rust engine, so Neovim never freezes while the database thinks. Results stick around for filtering, sorting, and reopening from history, even after you disconnect.

## Preview

<details open>
<summary>Screenshots</summary>

### Overview

![Overview](assets/overview.png)

</details>

<details>
<summary>Editing and table structure</summary>

### Editing results

![In-grid editing](assets/inline-edit.png)

### Table structure

![Table structure](assets/table-structure.png)

</details>

## Supported databases

- **SQL**: PostgreSQL, CockroachDB, MySQL, MariaDB, SQLite, DuckDB, ClickHouse, Oracle, SQL Server.
- **Document / KV**: Redis, Valkey, Dragonfly, MongoDB, SurrealDB.
- **Wide-column**: ScyllaDB, Cassandra.

## Installation

Requires Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim).

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

```lua
local install_engine = function()
  vim.schedule(function()
    require("sqmeow").install("cargo")
  end)
end

MiniDeps.add({
  source = "2giosangmitom/sqmeow.nvim",
  depends = { "MunifTanjim/nui.nvim" },
  hooks = { post_install = install_engine, post_checkout = install_engine },
})
```

Tracks the default branch and builds from source. For a release, set `checkout` to a tag and call `install()` in the hook.

</details>

<details>
<summary>vim.pack (Neovim 0.12+)</summary>

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
  { src = "https://github.com/2giosangmitom/sqmeow.nvim", version = vim.version.range(">=0.0.0") },
})
```

</details>

The hook downloads the matching engine binary (Linux x86_64/ARM64, Apple Silicon, Windows x86_64), so most people never build anything. To compile from source you need Rust and DuckDB; see [CONTRIBUTING.md](CONTRIBUTING.md).

After installing, run `:checkhealth sqmeow` to confirm everything is found. After rebuilding the engine yourself, run `:Sqmeow restart` so the new binary loads. To follow `master` instead of releases, drop the version pin and use `install("cargo")`.

## Usage

New here? Start with these four steps:

1. Run `:Sqmeow` to open the drawer and result window.
2. Press `A` in the drawer to add a connection.
3. Press `<CR>` on it to open, then `u` to run queries with it.
4. Press `a` for a scratchpad. Write a query, press `<CR>` to run.

To run only part of a file, select lines and press `<CR>`; `<leader>E` runs the whole buffer. Every window has its own shortcuts — press `?` anywhere to see them.

| Key            | Action                                              |
| -------------- | --------------------------------------------------- |
| `L` / `H`      | Next / previous result page                         |
| `K`            | Show the full row                                   |
| `gf` / `go`    | Open the filter / sort bar                          |
| `=`            | Filter rows by the value of the current cell        |
| `s` / `S`      | Sort by this column / add it to a multi-column sort |
| `i` then `gs`  | Edit a cell, then review; `<C-s>` applies to the DB |
| `x`            | Export to CSV, JSON, or SQL where supported         |
| `R`            | Clear filters, sorting, and hidden columns          |
| `p` / `P`      | Preview a table / open its query in an editor       |
| `gR`           | Follow foreign keys from a table or result column   |

Editing works when the result carries real table columns plus the full primary or unique key; each database adapter differs a little. When the database itself must forbid writes, connect with a read-only account rather than relying on the plugin.

Each database speaks its own language: SQL databases use their own dialect, Redis takes one command per line, MongoDB takes Extended JSON commands, ScyllaDB/Cassandra take CQL, and SurrealDB takes SurrealQL.

Filtering and sorting happen inside the plugin (Polars SQL) over the rows already fetched, including old history, so they work offline and never rerun your query. Rerun the query when you want fresh data.

Full reference: `:h sqmeow-commands`, `:h sqmeow-keymaps`, `:h sqmeow-queries`.

## Connections

You can add connections by hand in the drawer, or describe them per project in `.sqmeow/connections.toml` so teammates get the same setup through git:

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

When a project file and a saved connection share a name, the project file wins. Relative SQLite/DuckDB paths resolve from the project root, so the example above works for everyone who clones the repo.

### Credentials

Already have a full URL? Use it directly and keep the secret in an environment variable:

```toml
[dev]
url = "{{ env 'DATABASE_URL' }}"
read_only = true
```

Set `DATABASE_URL` in your shell or in a `.env` file next to `.sqmeow/`; the shell wins when both exist. Keep `.env` out of git and reconnect after changing it so the engine picks up the new values.

When the database hides behind another machine, tunnel through it with `ssh = "user@bastion"` or any Host alias from your `~/.ssh/config`. The database address is then resolved from that machine's point of view.

Details: `:h sqmeow-project`, `:h sqmeow-credentials`.

### Scratchpads

Keep queries under `.sqmeow/scratchpads/` (`.sql`, `.redis`, `.json`, `.surql`). In local scratchpads: `a` creates, `R` renames/moves, `d` deletes. Queries run on the selected connection.

## Completion

Works with `blink.cmp` and `nvim-cmp`. Install the `sql` Tree-sitter parser for column and alias completion (`:TSInstall sql`).

<details>
<summary>blink.cmp</summary>

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "buffer", "sqmeow" },
    providers = { sqmeow = { name = "Sqmeow", module = "sqmeow.completion.blink" } },
  },
})
```

</details>

<details>
<summary>nvim-cmp</summary>

```lua
local cmp = require("cmp")
cmp.register_source("sqmeow", require("sqmeow.completion.cmp").new())
cmp.setup({ sources = cmp.config.sources({ { name = "nvim_lsp" }, { name = "sqmeow" } }) })
```

</details>

See `:h sqmeow-completion`.

## Configuration

You only need `setup()` when the defaults don't suit you. The most-changed options, shown with their defaults:

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

`max_rows` limits how many rows are kept per result, while `page_size` limits how many show on one page. Setting either to `0` removes that limit (and `timeout_ms = 0` turns the deadline off).

Everything else: `:h sqmeow-config`. Changing shortcuts: `:h sqmeow-keymaps`.

## Acknowledgments

Ideas and some code from:

- [vim-dadbod](https://github.com/tpope/vim-dadbod)
- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)
- [nvim-dbee](https://github.com/kndndrj/nvim-dbee)
- [squix](https://github.com/eduardofuncao/squix)
- [DBeaver](https://github.com/dbeaver/dbeaver)

## Contributing

Issues and PRs welcome. Setup and checks: [CONTRIBUTING.md](CONTRIBUTING.md).

Thanks to all the [contributors](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors) 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)
