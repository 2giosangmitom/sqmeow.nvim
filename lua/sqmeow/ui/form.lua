--- A dialog that asks for several values at once.

local M = {}

local utils = require('sqmeow.utils')

--- What the form needs from its caller.
---@class sqmeow.FormSpec
---@field title string Drawn along the top of the dialog.
---@field fields sqmeow.Field[] In the order they are asked for.
---@field values table<string, string>|nil What each field starts as.
---@field wizard boolean|nil Open the first field for editing, and move on as each is answered.
---@field validate nil|fun(values: table<string, string>): string|nil What is wrong, if anything.
---@field on_submit fun(values: table<string, string>)
---@field on_cancel nil|fun()
---@field on_change nil|fun(values: table<string, string>, key: string) May adjust other values.
---@field preview nil|{ title: string, lines: string[]|(fun(values: table<string, string>): string[]), filetype: nil|string|(fun(values: table<string, string>): string) } Read-only pane below.

local NAMESPACE = vim.api.nvim_create_namespace('sqmeow-form')

--- The nui.nvim components this dialog is built from.
local function nui()
  return utils.nui({ 'popup', 'layout', 'input', 'line', 'text' }, 'this dialog')
end

--- Whether the dialog can be opened at all.
---@return boolean
function M.available()
  return nui() ~= nil
end

--- What a field's value looks like on screen.
---@param field sqmeow.Field
---@param value string
---@return string text
---@return string highlight
local function shown(field, value)
  if field.checkbox then
    return value == 'yes' and '[x]' or '[ ]', 'SqmeowFormValue'
  end
  if value == '' then
    return field.hint or '', 'SqmeowNull'
  end
  if field.mask then
    return ('*'):rep(vim.fn.strchars(value)), 'SqmeowFormValue'
  end
  return value, 'SqmeowFormValue'
end

--- Open the dialog.
---@param spec sqmeow.FormSpec
---@return boolean opened
---@return string|nil error
function M.open(spec)
  local parts, err = nui()
  if not parts then
    return false, err
  end

  -- Where focus goes back to.
  local origin = vim.api.nvim_get_current_win()

  local fields = spec.fields
  local values = vim.deepcopy(spec.values or {})
  for _, field in ipairs(fields) do
    values[field.key] = values[field.key] or ''
  end

  -- The value column starts past the longest label.
  local label_width = 0
  for _, field in ipairs(fields) do
    label_width = math.max(label_width, vim.fn.strdisplaywidth(field.label))
  end
  local gutter = 2
  local column = gutter + label_width + 2

  local width = math.max(56, column + 34)

  --- One of the dialog's windows, with the border and stacking every one of them shares.
  local function window(options, top, bottom)
    options.zindex = 100
    options.border = {
      style = require('sqmeow.config').border(),
      text = {
        top = (' %s '):format(top),
        top_align = 'center',
        bottom = bottom,
        bottom_align = 'center',
      },
    }
    return parts.Popup(options)
  end

  local popup = window(
    {
      enter = true,
      focusable = true,
      position = '40%',
      size = { width = width, height = #fields },
      buf_options = { filetype = 'sqmeow-form', modifiable = false },
      win_options = { cursorline = true, wrap = false },
    },
    spec.title,
    spec.preview and ' <CR> edit   <C-d>/<C-u> scroll   <C-s> save   q cancel '
      or ' <CR> edit   <C-s> save   q cancel '
  )

  -- With a preview the dialog grows into a column: the fields on top, the preview filling the rest.
  local layout, preview
  local preview_spec = spec.preview
  if preview_spec then
    preview = window({
      focusable = false,
      buf_options = {
        filetype = type(preview_spec.filetype) == 'string' and preview_spec.filetype or nil,
      },
      win_options = { wrap = false },
    }, preview_spec.title)
    layout = parts.Layout(
      {
        relative = 'editor',
        position = '50%',
        size = {
          width = math.max(math.floor(vim.o.columns * 0.6), width),
          height = math.max(math.floor(vim.o.lines * 0.6), #fields + 10),
        },
      },
      parts.Layout.Box({
        parts.Layout.Box(popup, { size = #fields + 2 }),
        parts.Layout.Box(preview, { grow = 1 }),
      }, { dir = 'col' })
    )
  end

  --- Fill the preview from the spec, working its lines and filetype out from the values when it
  --- gives them as functions.
  local function show_preview()
    local source = spec.preview
    if not (source and preview and preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr)) then
      return
    end
    local rendered = source.lines
    local lines = type(rendered) == 'function' and rendered(values) or rendered --[[@as string[] ]]
    vim.bo[preview.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(preview.bufnr, 0, -1, false, lines)
    vim.bo[preview.bufnr].modifiable = false
    if type(source.filetype) == 'function' then
      vim.bo[preview.bufnr].filetype = source.filetype(values)
    end
  end

  local function render()
    local blank = {}
    for _ = 1, #fields do
      table.insert(blank, '')
    end

    vim.bo[popup.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, blank)
    vim.api.nvim_buf_clear_namespace(popup.bufnr, NAMESPACE, 0, -1)

    for index, field in ipairs(fields) do
      local line = parts.Line()
      line:append((' '):rep(gutter))
      -- A field that does not apply to the other answers stays where it is, dimmed.
      local disabled = field.enabled ~= nil and not field.enabled(values)
      local text, group = shown(field, values[field.key])
      line:append(
        field.label .. (' '):rep(column - gutter - vim.fn.strdisplaywidth(field.label)),
        disabled and 'SqmeowNull' or 'SqmeowFormLabel'
      )
      line:append(text, disabled and 'SqmeowNull' or group)
      line:render(popup.bufnr, NAMESPACE, index)
    end

    vim.bo[popup.bufnr].modifiable = false
  end

  local function focus(index)
    -- A field closes after a delay, when the dialog may already be gone.
    if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
      vim.api.nvim_set_current_win(popup.winid)
      vim.api.nvim_win_set_cursor(popup.winid, { math.max(1, math.min(index, #fields)), 0 })
    end
  end

  local function current()
    if not vim.api.nvim_win_is_valid(popup.winid) then
      return 1
    end
    return vim.api.nvim_win_get_cursor(popup.winid)[1]
  end

  --- Hide what is being typed, not only what was typed.
  local function mask(winid)
    vim.wo[winid].conceallevel = 2
    vim.wo[winid].concealcursor = 'nvic'
    vim.fn.matchadd('Conceal', '.', 10, -1, { window = winid, conceal = '*' })
  end

  local function change(key, value)
    values[key] = value
    if spec.on_change then
      spec.on_change(values, key)
    end
    render()
    if spec.preview and type(spec.preview.lines) == 'function' then
      show_preview()
    end
  end

  --- The first field from `index` on that is typed into rather than chosen, for wizard mode.
  local function typed(index)
    while fields[index] and (fields[index].options or fields[index].checkbox) do
      index = index + 1
    end
    return index
  end

  local edit, submit, cancel
  edit = function(index)
    local field = fields[index]
    if not field then
      return
    end
    focus(index)
    if field.enabled and not field.enabled(values) then
      return
    end

    local options = field.options or (field.checkbox and { 'yes', 'no' })
    if options then
      local at = 0
      for position, option in ipairs(options) do
        if option == values[field.key] then
          at = position
        end
      end
      return change(field.key, options[at % #options + 1])
    end

    local input = parts.Input({
      relative = { type = 'win', winid = popup.winid },
      position = { row = index - 1, col = column },
      size = { width = vim.api.nvim_win_get_width(popup.winid) - column },
      zindex = 110,
      border = { style = 'none' },
      win_options = { winhighlight = 'Normal:SqmeowFormEdit' },
    }, {
      default_value = values[field.key],
      on_submit = function(value)
        change(field.key, value)
        -- In wizard mode one answer leads to the next.
        if spec.wizard and fields[typed(index + 1)] then
          return edit(typed(index + 1))
        end
        focus(math.min(index + 1, #fields))
      end,
      on_close = function()
        focus(index)
      end,
    })

    input:mount()
    if field.mask then
      mask(input.winid)
    end

    -- The dialog's keys work from an open field too: `q` cancels it, `<C-s>` saves what is typed.
    local opts = { noremap = true, nowait = true }
    input:map('n', 'q', function()
      input:unmount()
      cancel()
    end, opts)
    input:map('n', '<Esc>', function()
      input:unmount()
    end, opts)
    for _, mode in ipairs({ 'n', 'i' }) do
      input:map(mode, '<C-s>', function()
        local value = vim.api.nvim_buf_get_lines(input.bufnr, 0, 1, false)[1] or ''
        input:unmount()
        change(field.key, value)
        submit()
      end, opts)
    end
  end

  local function close()
    (layout or popup):unmount()
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end

  submit = function()
    local problem = spec.validate and spec.validate(values)
    if problem then
      popup.border:set_text('bottom', parts.Text((' %s '):format(problem), 'SqmeowError'), 'center')
      return
    end

    close()
    spec.on_submit(values)
  end

  if layout then
    layout:mount()
    show_preview()
  else
    popup:mount()
  end
  render()

  local map = function(keys, run)
    for _, key in ipairs(keys) do
      popup:map('n', key, run, { noremap = true, nowait = true })
    end
  end

  map({ '<CR>', 'i', 'a', 'c' }, function()
    edit(current())
  end)
  map({ '<Tab>' }, function()
    focus(current() % #fields + 1)
  end)
  map({ '<S-Tab>' }, function()
    focus((current() - 2) % #fields + 1)
  end)
  if preview then
    -- The preview takes no focus.
    for key, direction in pairs({ ['<C-d>'] = 1, ['<C-u>'] = -1 }) do
      map({ key }, function()
        if not vim.api.nvim_win_is_valid(preview.winid) then
          return
        end
        vim.api.nvim_win_call(preview.winid, function()
          local height = vim.api.nvim_win_get_height(0)
          local last = math.max(vim.api.nvim_buf_line_count(0) - height + 1, 1)
          local view = vim.fn.winsaveview()
          view.topline = math.min(
            math.max(view.topline + direction * math.max(math.floor(height / 2), 1), 1),
            last
          )
          view.lnum = view.topline
          vim.fn.winrestview(view)
        end)
      end)
    end
  end
  map({ '<C-s>' }, submit)
  cancel = function()
    close()
    if spec.on_cancel then
      spec.on_cancel()
    end
  end
  map({ 'q', '<Esc>' }, cancel)

  if spec.wizard then
    edit(typed(1))
  end

  return true
end

--- Ask which of a list of things the user means.
---@param opts { title: string, items: { label: string, icon: string|nil, highlight: string|nil, value: any }[], on_choice: fun(value: any) }
---@return boolean opened
---@return string|nil error
function M.menu(opts)
  local parts, err = nui()
  if not parts then
    return false, err
  end

  local ok, Menu = pcall(require, 'nui.menu')
  if not ok then
    return false, 'this dialog needs nui.nvim (MunifTanjim/nui.nvim)'
  end

  local width = 0
  local lines = {}
  for _, item in ipairs(opts.items) do
    local line = parts.Line()
    line:append('  ')
    if item.icon then
      line:append(item.icon .. ' ', item.highlight or 'SqmeowText')
    end
    line:append(item.label, 'SqmeowFormValue')
    width = math.max(width, line:width())
    table.insert(lines, Menu.item(line, { value = item.value }))
  end

  local menu = Menu({
    position = '40%',
    size = { width = math.max(width + 2, 32), height = #lines },
    zindex = 100,
    border = {
      style = require('sqmeow.config').border(),
      text = { top = (' %s '):format(opts.title), top_align = 'center' },
    },
    win_options = { cursorline = true },
  }, {
    lines = lines,
    keymap = {
      focus_next = { 'j', '<Down>', '<Tab>' },
      focus_prev = { 'k', '<Up>', '<S-Tab>' },
      close = { '<Esc>', '<C-c>', 'q' },
      submit = { '<CR>', '<Space>' },
    },
    on_submit = function(item)
      opts.on_choice(item.value)
    end,
  })

  menu:mount()
  return true
end

return M
