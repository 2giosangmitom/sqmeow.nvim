# 🐱 sqmeow.nvim

Query your database from your favorite editor.

[![Release](https://img.shields.io/github/v/release/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=github&color=a6da95&logoColor=D9E0EE&labelColor=302D41)](https://github.com/2giosangmitom/sqmeow.nvim/releases/latest)
![Stars](https://img.shields.io/github/stars/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=apachespark&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41)
![Last commit](https://img.shields.io/github/last-commit/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=github&color=7dc4e4&logoColor=D9E0EE&labelColor=302D41)
![Forks](https://img.shields.io/github/forks/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=starship&color=8bd5ca&logoColor=D9E0EE&labelColor=302D41)
![Issues](https://img.shields.io/github/issues/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=lightning&color=8bd5ca&logoColor=D9E0EE&labelColor=302D41)
![Repo size](https://img.shields.io/github/repo-size/2giosangmitom/sqmeow.nvim?color=%23DDB6F2&label=SIZE&logo=codesandbox&style=for-the-badge&logoColor=D9E0EE&labelColor=302D41)
![License](https://img.shields.io/github/license/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=alpinedotjs&color=ee999f&logoColor=D9E0EE&labelColor=302D41)

## ✨ Features

- **⚡ Rust engine**: Queries run off the editor thread and results are paged, so large results never freeze Neovim.
- **🐘 Multiple connections**: Keep several databases open at once.
- **🌲 Schema drawer**: Browse schemas, tables, views, routines and columns with their types and keys.
- **📄 Scratchpads**: Query buffers tied to a connection, kept across restarts.
- **✏️ In-grid editing**: Edit cells, add or delete rows, and review staged changes before applying them.
- **🔎 Filter and sort**: Type a `WHERE` condition and an `ORDER BY` list in a bar above the grid, and the database runs them on your query.
- **▶️ Flexible execution**: Run the statement under the cursor, a selection, or the whole buffer,
  with a result for each statement that returns rows.
- **🧭 EXPLAIN**: Query plans and errors show in the result window.
- **🕘 Query log**: Reopen the result of any past query, even after a restart.
- **📤 Export**: Results or selected rows to CSV, JSON or SQL `INSERT` statements, as a file or on
  the clipboard.
- **🔐 Secrets**: Passwords are masked, and URLs can read them with `{{ env "VAR" }}` or `{{ exec "cmd" }}`.
- **⌨️ Buffer-local keymaps**: No global mappings; `<Plug>` mappings for everything worth a global key.

## 🗄️ Supported Databases

- PostgreSQL, and servers speaking its protocol such as CockroachDB
- MySQL, MariaDB
- SQLite
- DuckDB
- Redis, Valkey, Dragonfly
- MongoDB
- ScyllaDB, Apache Cassandra

## 🎬 Preview

![preview](./assets/preview.webp)

## 🚀 Installation

**Requirements**: Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim).

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  '2giosangmitom/sqmeow.nvim',
  dependencies = { 'MunifTanjim/nui.nvim' },
  version = '*',
  build = function()
    -- Downloads the matching release binary; pass 'curl', 'wget', 'powershell' or 'cargo' to choose.
    require('sqmeow').install()
  end,
  opts = {},
}
```

> [!NOTE]
> To track `master`, remove `version` and build with `install('cargo')`, which needs a Rust toolchain and DuckDB installed.
> Run `:checkhealth sqmeow` to verify the installation.

## ⚡ Quick Start

1. `:Sqmeow` opens the drawer and the result window.
2. `A` in the drawer, or `:Sqmeow add`, adds a connection.
3. `<CR>` on a connection connects; `a` creates a scratchpad for it.
4. Write a query and press `<CR>` to run the statement under the cursor, or a visual selection.

> [!TIP]
> Press `?` in the drawer or the result window to list its keymaps.

### Dialect Notes

- **SQL**: `<CR>` runs the statement under the cursor; `<leader>E` runs the whole buffer.
- **Redis**: One command per line, such as `GET key`. The drawer lists keys by type.
- **MongoDB**: Database commands as Extended JSON, such as `{"find": "users"}`. `use db_name` switches database.

### Environment Connections

Define connections in `SQMEOW_CONNECTIONS`:

```sh
export SQMEOW_CONNECTIONS='[{"name": "dev", "url": "postgres://app:{{ env \"PGPASSWORD\" }}@localhost/dev"}]'
```

### Safety

- Tick **Read only** in the connection dialog, or add `"read_only": true` to a connection here or in
  `connections.json`, to run only statements that
  read and refuse edits. It guards against mistakes; a database user without write access is the real
  protection.
- Before a `DELETE` or `UPDATE` without `WHERE`, a `DROP`, a `TRUNCATE`, or emptying a Redis or
  MongoDB database, sqmeow asks first. Set `query.confirm_destructive = false` to turn it off.

## ⌨️ Commands

| Command                                             | Description                                         |
| --------------------------------------------------- | --------------------------------------------------- |
| `:Sqmeow`                                           | Open the drawer and the result window               |
| `:Sqmeow toggle`                                    | Show or hide the schema drawer                      |
| `:Sqmeow drawer`                                    | Show the schema drawer                              |
| `:Sqmeow open` / `close`                            | Show / hide the result window                       |
| `:Sqmeow add`                                       | Add a connection                                    |
| `:Sqmeow save`                                      | Save a connection for next time                     |
| `:Sqmeow edit [name]`                               | Edit a saved connection                             |
| `:Sqmeow use [name]`                                | Choose the connection queries run against           |
| `:Sqmeow bind <name\|none>`                         | Tie the current buffer to a connection, or untie it |
| `:Sqmeow disconnect`                                | Close the current connection                        |
| `:Sqmeow scratch [name]`                            | Create a scratchpad for a connection                |
| `:Sqmeow execute [sql]`                             | Run the buffer, the selection, or the given SQL     |
| `:Sqmeow statement`                                 | Run the statement under the cursor                  |
| `:Sqmeow cancel`                                    | Stop the running query                              |
| `:Sqmeow next` / `prev`                             | Show the next / previous page                       |
| `:Sqmeow float`                                     | Move the result between its split and a float       |
| `:Sqmeow review`                                    | Review and apply staged edits                       |
| `:Sqmeow export <csv\|json\|sql> [path\|clipboard]` | Export the result to a file or the clipboard        |
| `:Sqmeow log [clear]`                               | Reopen a past query's result, or clear the log      |
| `:Sqmeow install [method]`                          | Install the engine binary                           |
| `:Sqmeow start` / `stop` / `restart`                | Start, stop or restart the engine                   |
| `:Sqmeow messages`                                  | Show the engine's log                               |
| `:Sqmeow health`                                    | Run the health check                                |

## 🗺️ Keymaps

### Drawer

| Key         | Action                                  |
| ----------- | --------------------------------------- |
| `<CR>`, `o` | Expand or collapse the node             |
| `u`         | Run queries against this connection     |
| `p`         | Preview the relation's first page       |
| `K`         | Show the table's columns and indexes    |
| `r`         | Reload the subtree                      |
| `y` / `s`   | Yank the qualified name / a `SELECT`    |
| `a`         | Create a scratchpad                     |
| `A` / `e`   | Add / edit a connection                 |
| `R`         | Rename the connection or scratchpad     |
| `d`         | Delete the scratchpad, or clear the log |
| `?` / `q`   | Show keymaps / close the drawer         |

### Result Window

| Key         | Action                                       |
| ----------- | -------------------------------------------- |
| `L` / `H`   | Next / previous page                         |
| `gg` / `G`  | First / last page                            |
| `K`         | Show the row's details                       |
| `gK`        | Show the table's columns and indexes         |
| `]r` / `[r` | Show the next / previous statement's result  |
| `x`         | Export the result, or the selected rows      |
| `gf` / `go` | Open the filter bar on `WHERE` / `ORDER BY`  |
| `=`         | Filter by the cell's value                   |
| `s` / `S`   | Sort by the column / add it to the sort      |
| `-` / `g-`  | Hide the column / show hidden columns        |
| `R`         | Clear filters, sort and hidden columns       |
| `Z`         | Move between split and float                 |
| `?` / `q`   | Show keymaps / close the result window       |

### Filter Bar

`gf` and `go` open a bar above the grid with a `WHERE` line and an `ORDER BY` line. The query runs
again as a subquery narrowed and ordered by them, so they take any SQL the database accepts, and the
rows stay editable. `=` adds the cell's value to the `WHERE` line, and `s` fills the `ORDER BY` line.
Redis, MongoDB and ScyllaDB results are filtered and sorted in memory instead.

| Key               | Action                                |
| ----------------- | ------------------------------------- |
| `<CR>`            | Run the query with what the bar holds |
| `q`, `<Esc>`      | Close the bar without filtering       |
| `<C-p>` / `<C-n>` | Show an older / newer filter          |
| `<C-x><C-o>`      | Complete a column name                |

### Editing Results

A column is editable when it is a plain table column and its table's whole primary key, or failing
that a whole unique key, is in the result, so joined, filtered and sorted queries can be edited. Changes to a joined row update each
table by its own key, a deleted row is removed from the table of the first editable column, and rows
can only be added to a result from one table. Computed columns such as aggregates stay read-only.
After applying, the query runs again and opens at the same page and cursor.

| Key           | Action                                                    |
| ------------- | --------------------------------------------------------- |
| `i`, `<CR>`   | Edit the cell                                             |
| `X`           | Set the cell to `NULL`                                    |
| `o` / `D`     | Add a row / a copy of this row without its primary key    |
| `dd` / `d`    | Delete the row / the selected rows                        |
| `u` / `U`     | Undo the last change / discard all changes                |
| `gs`, `<C-s>` | Review staged changes; `<C-s>` in the review applies them |

### Scratchpad

| Key             | Action                             |
| --------------- | ---------------------------------- |
| `<CR>`          | Run the statement under the cursor |
| `<CR>` (visual) | Run the selection                  |
| `<leader>E`     | Run the whole buffer               |
| `<C-c>`         | Stop the running query             |

### Global Keymaps

Bind the `<Plug>` mappings to keys of your own:

```lua
vim.keymap.set('n', '<leader>dd', '<Plug>(sqmeow-toggle)')
vim.keymap.set('n', '<leader>de', '<Plug>(sqmeow-execute)')
vim.keymap.set('n', '<leader>dc', '<Plug>(sqmeow-cancel)')
vim.keymap.set('n', '<leader>da', '<Plug>(sqmeow-add-connection)')
vim.keymap.set('n', '<leader>ds', '<Plug>(sqmeow-scratch)')
vim.keymap.set('n', '<leader>df', '<Plug>(sqmeow-result-float)')
```

## ⚙️ Configuration

`setup()` is optional. The defaults:

```lua
require('sqmeow').setup({
  sources = { { type = 'file' }, { type = 'env' } }, -- where connections are loaded from
  core = {
    path = vim.fs.joinpath(vim.fn.stdpath('data'), 'sqmeow'), -- engine, connections, scratchpads, log
    log_level = 'warn',
  },
  ui = {
    drawer = { width = 36 },
    result = { height = 16, page_size = 100, max_column_width = 48, column_icons = true, null_text = 'NULL' },
    border = 'default', -- 'default' follows 'winborder'; or a nui style such as 'rounded'
    winbar = true,
    persist_session = false,
  },
  query = {
    max_rows = 100000,
    timeout_ms = 0, -- 0 disables the timeout
    history_size = 32, -- results kept in memory
    persist_history = true, -- save the log and its results to disk
    history_limit = 500,
    confirm_destructive = true, -- ask before DELETE/UPDATE without WHERE, DROP, TRUNCATE
  },
  icons = {}, -- Nerd Font glyphs; recolour them through the SqmeowIcon* highlight groups
  keymaps = {},
  redact_urls = true, -- mask passwords wherever a URL is shown
})
```

See `:h sqmeow-config` for every option.

## 🤝 Contributing

The toolchain is pinned with [mise](https://mise.jdx.dev) and tasks are [just](https://just.systems) recipes:

```sh
mise install   # rust, just, stylua, selene, lua-language-server
just db-up     # start the test databases in Docker
just           # lint, test and check the help file, as CI does
just docs      # regenerate doc/sqmeow.txt
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org).

## 📜 License

[MIT](LICENSE). Thanks to all [contributors](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors) 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)

## 🎖️ Acknowledgments

Inspired by [vim-dadbod](https://github.com/tpope/vim-dadbod), [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), and [nvim-dbee](https://github.com/kndndrj/nvim-dbee).
