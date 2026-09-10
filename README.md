# sqmeow.nvim

A database client for Neovim: a Lua frontend over a Rust engine.

The engine owns connections, queries, type decoding, and the layout of result grids. The plugin
owns windows, buffers, and keymaps. No row of data is ever formatted in Lua, which is what keeps a
large result from stalling the editor.

> Early development. SQLite, PostgreSQL and MySQL work end to end: connect, browse the schema,
> run SQL, and read a paginated grid. Nothing here is stable yet.

## Requirements

- Neovim 0.10 or newer
- No database client tools, and no Rust toolchain once prebuilt engines ship

## Trying it

```vim
:Sqmeow connect sqlite://./app.db
:Sqmeow connect postgres://user@localhost/app
:Sqmeow connect mysql://user@localhost/app
```

Then open a `.sql` buffer and run it:

```vim
:Sqmeow execute
```

Results land in a split below. `L` and `H` page through them, `q` closes the window, and
`:Sqmeow cancel` stops a query that is taking too long.

`:Sqmeow toggle` opens the schema drawer: connections, then schemas, then tables and views, then
columns with their types and keys. Each level loads when you expand it, so a database with ten
thousand tables opens as fast as one with ten.

## Keys

The plugin sets no global mappings. Every key it binds is buffer-local to one of its own windows,
carries a description that which-key will show, and can be changed or removed:

```lua
require('sqmeow').setup({
  keymaps = {
    result = { next_page = '<C-n>' },
    drawer = { yank_select = false },
  },
})
```

Press `?` in any plugin window for that window's keys. For anything you want on a key of your own,
bind a `<Plug>` mapping:

```lua
vim.keymap.set('n', '<leader>dd', '<Plug>(sqmeow-toggle)')
vim.keymap.set('n', '<leader>de', '<Plug>(sqmeow-execute)')
vim.keymap.set('n', '<leader>dc', '<Plug>(sqmeow-cancel)')
```

## Connections

`:Sqmeow save` writes a connection to a JSON file under `stdpath('data')`, and `:Sqmeow connect`
with no argument offers everything the configured sources know about. Four sources ship with the
plugin: inline connections from `setup()`, a JSON file, a JSON environment variable, and `g:dbs`
for anyone arriving from vim-dadbod.

Passwords do not have to be written down. A URL may hold a directive that the engine expands when
it connects, and never logs, echoes, or sends back to the editor:

```
postgres://app:{{ env "PGPASSWORD" }}@localhost/dev
postgres://app:{{ exec "pass show db/prod" }}@db.internal/app
```

Everywhere a URL is displayed, the password is masked. Set `redact_urls = false` to turn that off.

## Status

| Milestone | State |
| --- | --- |
| Channel to the engine, configuration, health check | done |
| SQLite, end to end | done |
| PostgreSQL and MySQL | done |
| Schema drawer and keymap system | done |
| Editor and result grid | next |
| Statusline and picker integrations | planned |
| Generated documentation and prebuilt releases | planned |

## Development

The toolchain is pinned with [mise](https://mise.jdx.dev), and every command CI runs is a
[just](https://just.systems) recipe.

```sh
mise install     # rust, just, stylua, selene
just deps        # clone mini.nvim, used for tests and docs
just db-up       # PostgreSQL and MySQL for the integration tests
just             # lint and test, the same way CI does
just build       # release engine, which the plugin prefers to load
```

The PostgreSQL and MySQL tests report themselves skipped when those servers are not running, so
`just test` works without Docker. It just covers less.

The plugin finds an engine in three places, in this order: `core.path` from your configuration, the
managed copy under `stdpath('data')`, and a local `cargo build` inside the plugin directory. The
last one means a checkout works with no install step.

Run `:checkhealth sqmeow` to see which engine is in use and whether it matches this plugin.

## License

MIT
