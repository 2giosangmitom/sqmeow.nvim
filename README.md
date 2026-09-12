# sqmeow.nvim

A database client for Neovim: a Lua frontend over a Rust engine.

The engine owns connections, queries, type decoding, and the layout of result grids. The plugin
owns windows, buffers, and keymaps. No row of data is ever formatted in Lua, which is what keeps a
large result from stalling the editor.

> Early development. SQLite, PostgreSQL and MySQL work end to end: connect, browse the schema,
> run SQL, read a paginated grid, and export it. Nothing here is stable yet.

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

Results land in a split below, one buffer holding the column names and the rows. `L` and `H`
page through them, `K` opens the row under the cursor down the page so long values are readable in
full, `yc` and `yr` yank a cell or a row, and `q` closes the window. `:Sqmeow cancel` stops a query
that is taking too long.

`:Sqmeow toggle` opens the schema drawer. A connection holds schemas, a schema holds four headings,
and each heading says how many things it holds before you open it:

```
v postgres-db
  v broadcast
    > Tables (13)
    > Views (2)
      Functions (0)
      Procedures (0)
  > company
  > public
```

Under Tables and Views are the relations, and under a relation its columns with their types and
keys. Functions and Procedures are the stored routines the schema holds, which SQLite has none of.
An empty heading stays closed, because opening it would show nothing and the count already said so.
Every level loads when you expand it, so a database with ten thousand tables opens as fast as one
with ten.

`:Sqmeow scratch` opens a scratchpad for the current connection, an ordinary `sql` file under
`stdpath('data')` that survives a restart. In it, `<CR>` runs the statement the cursor is in and
`<CR>` on a selection runs that. A statement that fails becomes a diagnostic on its own lines
rather than a message that scrolls away.

Every scratchpad you have written is listed in the drawer under its own heading, below the
connections. `<CR>` on one opens it, in a real editing window rather than in the sidebar, `R`
renames it, and `d` deletes it after asking. Both prompts start from the current name, so a stray
keypress followed by `<Esc>` changes nothing. `:Sqmeow find scratchpads` is the same list as a
fuzzy picker, and `:Sqmeow scratch <name>` opens or creates one under a name of your choosing.

`:Sqmeow export csv` writes the whole result to a file, and `:Sqmeow log` lists what has been run
and puts any of it back on screen without running it again.

`:Sqmeow find relations` fuzzy-finds a table anywhere in the connection, through whichever picker
you already use.

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
vim.keymap.set('n', '<leader>dr', '<Plug>(sqmeow-relations)')
vim.keymap.set('n', '<leader>dh', '<Plug>(sqmeow-history)')
```

## Pickers

`:Sqmeow find` opens one of five lists, and each one is shown with whichever fuzzy picker you
already have. telescope, fzf-lua and snacks.picker are all detected at the moment the list opens,
so none of them is a dependency and having none of them still works through `vim.ui.select`.

| List | What it does |
| --- | --- |
| `connections` | switch the current connection, or open a saved one |
| `relations` | find a table or a view anywhere in the connection |
| `history` | put a past result back on screen without running it again |
| `scratchpads` | open a saved query buffer |
| `columns` | jump to a column of the current result |

`f` opens the relevant one from inside a plugin window: the relation list from the drawer, scoped
to the schema you are standing in, and the column list from the result grid. telescope users also
get `:Telescope sqmeow relations` once the extension is loaded:

```lua
require('telescope').load_extension('sqmeow')
```

The relation list is read once per connection and then held, so it opens instantly after the first
time. A schema you cannot read is left out rather than emptying the list.

## Statusline

`require('sqmeow.status').get()` returns a plain table: the connection, its dialect, what the last
query is doing, and how big its result was. Anything that renders a statusline can read it.

For lualine there is a component built on top of it, named `sqmeow`:

```lua
require('lualine').setup({
  sections = { lualine_x = { 'sqmeow' } },
})
```

It shows nothing until you connect, spins while a query runs, and reports the row count and how
long it took when one finishes.

Name it as a string rather than calling `require`. A lazy.nvim spec is read before any plugin is
on the runtime path, so `require('sqmeow.lualine')` inside an `opts` table runs too early and the
component never arrives:

```lua
{
  'nvim-lualine/lualine.nvim',
  -- lualine looks the component up by name when it is configured, so this plugin has to be on
  -- the runtime path by then. That is all the dependency is for.
  dependencies = { '2giosangmitom/sqmeow.nvim' },
  opts = {
    sections = { lualine_x = { 'sqmeow' } },
  },
}
```

`require('sqmeow.lualine')` returns the same component for anyone configuring lualine somewhere a
`require` is safe.

## Icons and notifications

Every character the plugin draws that is not text lives in one `icons` table, and all of it is
yours to change. The defaults are Nerd Font glyphs, so a terminal without one is dressed by setting
them rather than by the plugin guessing at your font. No icon plugin is consulted: mini.icons and
nvim-web-devicons map file types, and a materialised view is not a file.

```lua
require('sqmeow').setup({
  icons = {
    table = '',
    view = '',
    postgres = '',
    -- What sits before a drawer row, by whether its children are showing.
    markers = { open = 'v', closed = '>', leaf = ' ' },
    -- Cycled while a query runs. Any number of frames works.
    spinner = { '|', '/', '-', '\\' },
    -- What the engine draws the result grid with.
    grid = { vertical = '|', horizontal = '-', cross = '+', ellipsis = '~' },
  },
})
```

The kinds are `connection`, `schema`, `table`, `view`, `materialized view`, `relation`, `column`,
`scratchpads`, `scratchpad`, `query`, and the dialects `postgres`, `mysql` and `sqlite`. A
connection wears its own dialect's icon, so a drawer holding three databases tells them apart
without reading a word. Naming a kind that does not exist is a configuration error rather than a
setting that quietly does nothing.

The three grid separators have to be one column wide. A wider one is ignored, because a rule drawn
from it would no longer line up with the header above it. The ellipsis may be any width, since the
column it truncates is measured against whatever it is.

Colours are not set there. Every icon has a `SqmeowIcon*` highlight group and the expand markers
share `SqmeowMarker`, which follows `Comment`. Each links to a standard group so any colourscheme
works, and redefining one is how you recolour it:

```lua
vim.api.nvim_set_hl(0, 'SqmeowIconTable', { fg = '#7aa2f7' })
vim.api.nvim_set_hl(0, 'SqmeowMarker', { link = 'NonText' })
```

Long operations report through `vim.notify`, so nvim-notify, snacks.notifier and dressing.nvim all
render them, and connecting rewrites its own message rather than stacking a second one. Set
`integrations.notify = false` to keep everything but the errors quiet.

## Connections

`:Sqmeow save` writes a connection to a JSON file under `stdpath('data')`, and `:Sqmeow connect`
with no argument offers everything the configured sources know about. Three sources ship with the
plugin: inline connections from `setup()`, a JSON file, and a JSON environment variable.

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
| Editor and result grid | done |
| Statusline and picker integrations | done |
| Generated documentation and prebuilt releases | done |

## Documentation

`:help sqmeow` is generated from the annotated sources with
[mini.doc](https://github.com/nvim-mini/mini.doc) and committed, because plugin managers do not run
build steps. The default configuration and the keymap table are evaluated at generation time and
inlined, so the documented defaults are literally the ones the code uses and cannot fall behind.
`just docs` regenerates it, and CI fails a pull request that changes an annotation without doing so.

The protocol the two halves speak is written down in [core/PROTOCOL.md](core/PROTOCOL.md). It is the
contract both sides code against, so a field cannot change without that document changing first.

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

When there is none, the first call that needs an engine downloads one. A release cross-compiles
for Linux, macOS and Windows on both x86-64 and ARM, and publishes a manifest naming each archive
and its SHA-256, which is what the download verifies against. If no prebuilt target
matches, and only then, it falls back to `cargo build --release`. `:Sqmeow update` does the same
thing on demand, and `core.auto_install = false` turns the automatic path off.

Run `:checkhealth sqmeow` to see which engine is in use and whether it matches this plugin.

## Releases

Versions are cut from the commit log by
[release-please](https://github.com/googleapis/release-please), so commit messages are the release
notes. Write them as [conventional commits](https://www.conventionalcommits.org): `feat:` for
anything a user would notice, `fix:` for a repair, and a `!` or a `BREAKING CHANGE:` trailer for
something that changes how the plugin is used.

Every merge to `master` updates a standing pull request holding the next version number and the
changelog it would ship. Nothing is released until that pull request is merged. Merging it tags the
commit, writes `CHANGELOG.md`, and starts the cross-compilation, so the archives and the manifest
land on the release the changelog describes.

The version appears in three places, and all three move together: the Rust workspace, the plugin
version sent at handshake, and the lockfile. Do not edit them by hand.

## License

MIT
