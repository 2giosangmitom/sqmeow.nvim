# sqmeow.nvim

A database client for Neovim: a Lua frontend over a Rust engine.

The engine owns connections, queries, type decoding, and the layout of result grids. The plugin
owns windows, buffers, and keymaps. No row of data is ever formatted in Lua, which is what keeps a
large result from stalling the editor.

> Early development. SQLite works end to end: connect, run SQL, and read a paginated grid.
> PostgreSQL and MySQL are next. Nothing here is stable yet.

## Requirements

- Neovim 0.10 or newer
- No database client tools, and no Rust toolchain once prebuilt engines ship

## Trying it

```vim
:Sqmeow connect sqlite://./app.db
```

Then open a `.sql` buffer and run it:

```vim
:Sqmeow execute
```

Results land in a split below. `L` and `H` page through them, `q` closes the window, and
`:Sqmeow cancel` stops a query that is taking too long.

## Status

| Milestone | State |
| --- | --- |
| Channel to the engine, configuration, health check | done |
| SQLite, end to end | done |
| PostgreSQL and MySQL | next |
| Schema drawer and keymap system | planned |
| Editor and result grid | planned |
| Statusline and picker integrations | planned |
| Generated documentation and prebuilt releases | planned |

## Development

The toolchain is pinned with [mise](https://mise.jdx.dev), and every command CI runs is a
[just](https://just.systems) recipe.

```sh
mise install     # rust, just, stylua, selene
just deps        # clone mini.nvim, used for tests and docs
just             # lint and test, the same way CI does
just build       # release engine, which the plugin prefers to load
```

The plugin finds an engine in three places, in this order: `core.path` from your configuration, the
managed copy under `stdpath('data')`, and a local `cargo build` inside the plugin directory. The
last one means a checkout works with no install step.

Run `:checkhealth sqmeow` to see which engine is in use and whether it matches this plugin.

## License

MIT
