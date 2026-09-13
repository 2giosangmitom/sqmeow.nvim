# 🐱 sqmeow.nvim

Query your database from your favorite editor. _sqmeow.nvim_ is a database client for Neovim: a Lua frontend over a Rust engine.

![Stars](https://img.shields.io/github/stars/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=apachespark&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41)
![Last commit](https://img.shields.io/github/last-commit/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=github&color=7dc4e4&logoColor=D9E0EE&labelColor=302D41)
![Forks](https://img.shields.io/github/forks/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=starship&color=8bd5ca&logoColor=D9E0EE&labelColor=302D41)
![Issues](https://img.shields.io/github/issues/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=lightning&color=8bd5ca&logoColor=D9E0EE&labelColor=302D41)
![Repo size](https://img.shields.io/github/repo-size/2giosangmitom/sqmeow.nvim?color=%23DDB6F2&label=SIZE&logo=codesandbox&style=for-the-badge&logoColor=D9E0EE&labelColor=302D41)
![LICENSE](https://img.shields.io/github/license/2giosangmitom/sqmeow.nvim?style=for-the-badge&logo=alpinedotjs&color=ee999f&logoColor=D9E0EE&labelColor=302D41)

## ✨ Features

- 🐘 Several connections open at once, each to a different database if you like.
- 🖥️ One command opens the client: schema drawer and result grid.
- 📝 A connection form with real fields, so nobody types a URL by hand. The password stays hidden behind asterisks.
- 🌲 A schema drawer with tables, views, functions, procedures and columns with their types and keys, loaded as you expand.
- ▶️ Run the statement under the cursor, a selection or the whole buffer. Errors show up as diagnostics on their own lines.
- 📄 Scratchpads you create and name from the drawer, as many per connection as you like. They survive a restart and stay tied to their connection, so two of them can query two databases side by side.
- 🕘 A query log that keeps every result, so you can look at yesterday's answer without running the query again.
- ⚡ Rows are decoded in Rust and shown a page at a time, so a large result never stalls the editor. Yank as CSV or export to CSV and JSON.
- 🔐 Passwords can come from `{{ env "VAR" }}` or `{{ exec "cmd" }}`, and are masked wherever a URL is shown.
- ⌨️ No global keymaps. Every key is buffer-local and configurable, with `<Plug>` mappings for your own bindings.

<a id="supported-databases"></a>

## 🗄️ Supported databases

- SQLite
- PostgreSQL
- MySQL, MariaDB
- Redis, Valkey, Dragonfly

## 🎬 Preview

![preview](./assets/preview.webp)

## 🚀 Installation

Requires Neovim 0.10+ and [nui.nvim](https://github.com/MunifTanjim/nui.nvim). The engine is a separate binary and is never installed automatically, so call `install()` from your plugin manager's build hook.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  '2giosangmitom/sqmeow.nvim',
  dependencies = { 'MunifTanjim/nui.nvim' },
  version = '*',
  build = function()
    -- Downloads the matching release. Pass 'curl', 'wget', 'powershell' or 'cargo' to choose.
    require('sqmeow').install()
  end,
  opts = {},
}
```

To track the latest commit instead of a release, drop `version` and use `install('cargo')`, which needs a Rust toolchain. `:Sqmeow install [method]` installs from inside a session, and `:checkhealth sqmeow` shows which engine is running.

## ⚡ Usage

1. `:Sqmeow` opens the drawer and the result window. Run it again to restore your layout.
2. `:Sqmeow add` (or `A` in the drawer) opens a form to add a connection. Leave the database empty to list every database on the server.
3. `<CR>` on a connection in the drawer opens it. `u` makes it the one queries run against, and `a` creates a scratchpad for it.
4. Write SQL in the scratchpad and press `<CR>` to run the statement under the cursor, or a visual selection. Errors show as diagnostics. On a Redis connection, write one command per line; the drawer lists keys by type.

Press `?` in the drawer or result window to list its keys.

Connections are stored in `connections.json` under `core.path`. They can also come from the `SQMEOW_CONNECTIONS` environment variable, as a JSON array:

```sh
export SQMEOW_CONNECTIONS='[{"name": "dev", "url": "postgres://app:{{ env \"PGPASSWORD\" }}@localhost/dev"}]'
```

### Commands

| Command                      | Description                                         |
| ---------------------------- | --------------------------------------------------- |
| `:Sqmeow`                    | Open every window, or restore the layout            |
| `:Sqmeow toggle`             | Open every window, or close them                    |
| `:Sqmeow add`                | Add a connection                                    |
| `:Sqmeow edit [name]`        | Edit a saved connection                             |
| `:Sqmeow use [name]`         | Choose the connection queries run against           |
| `:Sqmeow bind <name\|none>`  | Tie the current buffer to a connection, or untie it |
| `:Sqmeow disconnect`         | Close the current connection                        |
| `:Sqmeow scratch [name]`     | Create a scratchpad for a connection                |
| `:Sqmeow execute [sql]`      | Run the buffer, the selection, or the given SQL     |
| `:Sqmeow cancel`             | Stop the running query                              |
| `:Sqmeow export <csv\|json>` | Write the result to a file                          |
| `:Sqmeow log [clear]`        | Show a past query's result, or clear the log        |
| `:Sqmeow install [method]`   | Install the engine                                  |
| `:Sqmeow health`             | Run the health check                                |

Subcommands complete with `<Tab>`. See `:h sqmeow` for the rest.

### Keymaps

**Drawer**

| Key         | Action                                 |
| ----------- | -------------------------------------- |
| `<CR>`, `o` | Expand or collapse                     |
| `u`         | Run queries against this connection    |
| `p`         | Preview the relation                   |
| `r`         | Reload the subtree                     |
| `y` / `s`   | Yank the qualified name / a `SELECT`   |
| `a`         | Create a scratchpad for the connection |
| `A` / `e`   | Add / edit a connection                |
| `R`         | Rename a connection or scratchpad      |
| `d`         | Delete a scratchpad, or empty the log  |
| `q`         | Close                                  |

**Result**

| Key                | Action                        |
| ------------------ | ----------------------------- |
| `L` / `H`          | Next / previous page          |
| `gg` / `G`         | First / last page             |
| `K`                | Show the row in detail        |
| `yc` / `yr` / `yp` | Yank cell / row / page as CSV |
| `e`                | Export the result             |
| `q`                | Close                         |

**Scratchpad**

| Key             | Action                             |
| --------------- | ---------------------------------- |
| `<CR>`          | Run the statement under the cursor |
| `<CR>` (visual) | Run the selection                  |
| `<leader>E`     | Run the whole buffer               |
| `<C-c>`         | Stop the running query             |

Override or disable (`false`) any key by action name, e.g. `keymaps = { result = { next_page = '<C-n>' } }`. The action names are listed in `:h sqmeow-keymaps`.

For global keys, bind the `<Plug>` mappings:

```lua
vim.keymap.set('n', '<leader>dd', '<Plug>(sqmeow-toggle)')
vim.keymap.set('n', '<leader>de', '<Plug>(sqmeow-execute)')
vim.keymap.set('n', '<leader>dc', '<Plug>(sqmeow-cancel)')
vim.keymap.set('n', '<leader>da', '<Plug>(sqmeow-add-connection)')
vim.keymap.set('n', '<leader>ds', '<Plug>(sqmeow-scratch)')
```

## ⚙️ Configuration

`setup()` is optional. These are the defaults (icons omitted):

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
    border = 'rounded',
    winbar = true,
    persist_session = false,
  },
  query = {
    max_rows = 100000,
    timeout_ms = 0, -- 0 disables the timeout
    history_size = 32, -- results kept in memory
    persist_history = true, -- save the query log and its results to disk
    history_limit = 500,
  },
  icons = {}, -- Nerd Font glyphs by default; recolour through the SqmeowIcon* highlight groups
  keymaps = {},
  redact_urls = true, -- mask passwords in displayed URLs
})
```

Unknown options are reported by name. See `:h sqmeow-config` for every option and icon.

## 🤝 Contributing

Contributions are welcome. The toolchain is pinned with [mise](https://mise.jdx.dev) and tasks are [just](https://just.systems) recipes:

```sh
mise install   # rust, just, stylua, selene
just db-up     # PostgreSQL, MySQL, Redis and Dragonfly for integration tests
just           # lint and test, as CI does
just docs      # regenerate doc/sqmeow.txt
```

Write commit messages as [conventional commits](https://www.conventionalcommits.org); they become the release notes.

## 📜 License

[MIT](LICENSE). Thanks to all the [contributors](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors) 💛

[![Contributors](https://contrib.rocks/image?repo=2giosangmitom/sqmeow.nvim)](https://github.com/2giosangmitom/sqmeow.nvim/graphs/contributors)

## 🎖️ Acknowledgments

Inspired by [vim-dadbod](https://github.com/tpope/vim-dadbod), [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui), and [nvim-dbee](https://github.com/kndndrj/nvim-dbee).
