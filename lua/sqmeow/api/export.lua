-- Export helper, standalone so callers require it directly.
-- No re-export through sqmeow.api.

local M = {}

local notify = require('sqmeow.core.utils').notify

local function engine()
  require('sqmeow.rpc.events').ensure()
  return require('sqmeow.rpc.client')
end

--- Export kept rows to a file or clipboard, async.
--- No `path`/`clipboard`: opens a preview dialog. Uses visible columns and the
--- current view unless `all` is true. Never reruns the query.
---@param opts table|nil `format`: `csv` (default), `json`, or `sql`; `path`: file
--- destination; `clipboard = true`: copy instead. `headers = false` omits CSV
--- headers. `offset` (zero-based) and `limit` select rows. SQL options: `table`
--- overrides the target, `batch` combines INSERT rows, `create` includes DDL.
--- `all = true` exports retained rows outside the current filtered view.
function M.export(opts)
  opts = opts or {}
  local state = require('sqmeow.core.state')
  local call = state.call
  if not (call and call.call_id) then
    notify('there is no result to export', vim.log.levels.WARN)
    return
  end

  -- SQL is written for the database the rows came from.
  local dialect = call.dialect or (state.connections[call.conn_id] or {}).dialect

  --- Without a path the engine sends the text back, and `export:done` puts it on the clipboard.
  ---@param extra table|nil `table`, `all`, `batch` and `create`.
  local function write(format, path, headers, extra)
    extra = extra or {}
    local _, err = engine().request('export', {
      call_id = call.call_id,
      format = format,
      headers = headers,
      table = extra.table,
      all = extra.all,
      batch = extra.batch,
      create = extra.create,
      dialect = dialect,
      offset = opts.offset,
      limit = opts.limit,
      columns = require('sqmeow.ui.result').visible_columns(),
      path = path and vim.fn.fnamemodify(vim.fs.normalize(path), ':p') or nil,
    })
    if err then
      notify(err, vim.log.levels.ERROR)
    end
  end

  if opts.path or opts.clipboard then
    return write(opts.format or 'csv', opts.path, opts.headers ~= false, opts)
  end

  -- Named after the table the query reads from, else the connection.
  local relation = (call.statement or ''):match('[Ff][Rr][Oo][Mm]%s+([%w_%.`"%[%]]+)')
  relation = relation and relation:gsub('[`"%[%]]', ''):match('([^.]+)$')
  local connection = call.connection or (state.connections[call.conn_id] or {}).name or 'result'
  local stem = (relation or connection):gsub('[^%w_-]', '_') .. os.date('_%Y%m%d_%H%M%S')

  local result = require('sqmeow.ui.result')
  --- The preview's title, for the rows chosen.
  local function title(values)
    local every = values.rows == 'All'
    local count = opts.limit or (not every and call.view_rows) or call.rows or 0
    local plural = count == 1 and '' or 's'
    local text = opts.limit and ('Preview of %d selected row%s'):format(count, plural)
      or ('Preview of %s %d row%s'):format(
        call.view_rows and not every and 'the' or 'all',
        count,
        plural
      )
    -- The engine renders at most this many rows for the preview.
    if count > 100 then
      text = ('%s, first 100'):format(text)
    end
    return text
  end

  -- Redis, MongoDB and SurrealDB have no SQL table to insert into.
  local sql = not vim.tbl_contains({ 'redis', 'mongodb', 'surrealdb' }, dialect)
  local formats = sql and { 'CSV', 'JSON', 'SQL' } or { 'CSV', 'JSON' }
  local format = (opts.format or 'csv'):upper()
  if not vim.list_contains(formats, format) then
    format = 'CSV'
  end
  local function is_sql(values)
    return values.format == 'SQL'
  end
  local function to_file(values)
    return values.destination ~= 'Clipboard'
  end
  -- The file the last refused save would have replaced.
  local confirmed

  local ok, err = require('sqmeow.ui.form').open({
    title = 'Export',
    fields = {
      { key = 'format', label = 'Format', options = formats },
      { key = 'filename', label = 'Filename', enabled = to_file },
      { key = 'path', label = 'Path', enabled = to_file },
      {
        key = 'headers',
        label = 'Include headers',
        checkbox = true,
        -- JSON names every value by its column, so there is no header to leave out.
        enabled = function(values)
          return values.format == 'CSV'
        end,
      },
      {
        key = 'table',
        label = 'Table',
        -- Left empty, the rows go into the table they came from.
        hint = call.source and call.source.kind == 'table' and call.source.name or 'result',
        enabled = is_sql,
      },
      {
        key = 'batch',
        label = 'Multi-row INSERT',
        checkbox = true,
        -- CQL has no multi-row VALUES.
        enabled = function(values)
          return is_sql(values) and dialect ~= 'scylla'
        end,
      },
      { key = 'create', label = 'Include CREATE TABLE', checkbox = true, enabled = is_sql },
      {
        key = 'rows',
        label = 'Rows',
        options = { 'Shown', 'All' },
        -- A selection is exact, and without a filter every row is shown.
        enabled = function()
          return not opts.limit and call.view_rows ~= nil
        end,
      },
      { key = 'destination', label = 'Destination', options = { 'File', 'Clipboard' } },
    },
    values = {
      format = format,
      destination = 'File',
      filename = stem .. '.' .. format:lower(),
      path = vim.fn.fnamemodify(vim.uv.cwd() or '.', ':~'),
      headers = 'yes',
      table = '',
      batch = 'no',
      create = 'no',
      rows = 'Shown',
    },
    -- What will be written, in the format chosen.
    preview = {
      title = title,
      filetype = function(values)
        return values.format:lower()
      end,
      lines = function(values)
        local text, problem = engine().request('export_preview', {
          call_id = call.call_id,
          format = values.format:lower(),
          headers = values.headers == 'yes',
          table = values.table,
          all = values.rows == 'All',
          batch = values.batch == 'yes',
          create = values.create == 'yes',
          dialect = dialect,
          offset = opts.offset,
          limit = opts.limit,
          columns = result.visible_columns(),
        })
        if not text then
          return { problem or 'there is nothing to preview' }
        end
        return vim.split((text:gsub('\n$', '')), '\n', { plain = true })
      end,
    },
    on_change = function(values, key)
      -- The extension follows the format, unless the user named the file something else.
      if key == 'format' then
        local bare = values.filename:match('^(.*)%.csv$')
          or values.filename:match('^(.*)%.json$')
          or values.filename:match('^(.*)%.sql$')
        if bare then
          values.filename = bare .. '.' .. values.format:lower()
        end
      end
    end,
    validate = function(values)
      if not to_file(values) then
        return
      end
      if vim.trim(values.filename) == '' then
        return 'a file name is needed'
      end
      if vim.trim(values.path) == '' then
        return 'a path is needed'
      end
      local directory = vim.fs.normalize(values.path)
      if vim.fn.isdirectory(directory) == 0 then
        return values.path .. ' is not a directory'
      end

      local target = vim.fs.joinpath(directory, values.filename)
      if vim.uv.fs_stat(target) and confirmed ~= target then
        confirmed = target
        return values.filename .. ' exists: <C-s> again to overwrite it'
      end
    end,
    on_submit = function(values)
      write(
        values.format:lower(),
        to_file(values) and vim.fs.joinpath(values.path, values.filename) or nil,
        values.headers == 'yes',
        {
          table = values.table,
          all = values.rows == 'All',
          batch = values.batch == 'yes',
          create = values.create == 'yes',
        }
      )
    end,
  })
  if not ok then
    notify(err or 'the export dialog could not open', vim.log.levels.ERROR)
  end
end

return M
