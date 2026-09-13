--- A dialog that asks for several values at once.
---
--- The plugin's answer to typing a connection string by hand. A form names every value it wants,
--- shows what is already there, keeps a password out of sight, and refuses to save something that
--- cannot work, none of which a single prompt asking for a URL can do.
---
--- Built on nui.nvim, which supplies the floating window and the single-line editor. The
--- dependency is loaded here and nowhere else, so a user without it gets one clear message from
--- the one feature that needs it rather than an error at startup.

local M = {}

--- What the form needs from its caller.
---@class sqmeow.FormSpec
---@field title string Drawn along the top of the dialog.
---@field fields sqmeow.Field[] In the order they are asked for.
---@field values table<string, string>|nil What each field starts as.
---@field wizard boolean|nil Open the first field for editing, and move on as each is answered.
---@field validate nil|fun(values: table<string, string>): string|nil What is wrong, if anything.
---@field on_submit fun(values: table<string, string>)
---@field on_cancel nil|fun()

local NAMESPACE = vim.api.nvim_create_namespace('sqmeow-form')

--- nui's pieces, or nil when it is not installed.
---
---@return table|nil
---@return string|nil error
local function nui()
  local modules = {}
  for name, path in pairs({
    Popup = 'nui.popup',
    Input = 'nui.input',
    Line = 'nui.line',
    Text = 'nui.text',
  }) do
    local ok, module = pcall(require, path)
    if not ok then
      return nil, 'sqmeow: the connection dialog needs nui.nvim (MunifTanjim/nui.nvim)'
    end
    modules[name] = module
  end
  return modules
end

--- Whether the dialog can be opened at all.
---
--- Used by `:checkhealth` so the missing dependency is reported before someone runs into it.
---
---@return boolean
function M.available()
  return nui() ~= nil
end

--- What a field's value looks like on screen.
---
--- A masked field shows one asterisk per character: enough to see that something is there and how
--- much of it, and nothing else.
---
---@param field sqmeow.Field
---@param value string
---@return string text
---@return string highlight
local function shown(field, value)
  if value == '' then
    return field.hint or '', 'SqmeowNull'
  end
  if field.mask then
    return ('*'):rep(vim.fn.strchars(value)), 'SqmeowFormValue'
  end
  return value, 'SqmeowFormValue'
end

--- Open the dialog.
---
--- Returns nothing useful: the form owns its window until the user saves or cancels, and reports
--- through the callbacks in the spec.
---
---@param spec sqmeow.FormSpec
---@return boolean opened
---@return string|nil error
function M.open(spec)
  local parts, err = nui()
  if not parts then
    return false, err
  end

  local fields = spec.fields
  local values = vim.deepcopy(spec.values or {})
  for _, field in ipairs(fields) do
    values[field.key] = values[field.key] or ''
  end

  -- The value column starts past the longest label, so every value lines up however the labels
  -- are worded.
  local label_width = 0
  for _, field in ipairs(fields) do
    label_width = math.max(label_width, vim.fn.strdisplaywidth(field.label))
  end
  local gutter = 2
  local column = gutter + label_width + 2

  local width = math.max(56, column + 34)
  local border = require('sqmeow.config').border()

  local popup = parts.Popup({
    enter = true,
    focusable = true,
    position = '40%',
    size = { width = width, height = #fields },
    zindex = 100,
    border = {
      style = border,
      text = {
        top = (' %s '):format(spec.title),
        top_align = 'center',
        bottom = ' <CR> edit   <C-s> save   q cancel ',
        bottom_align = 'center',
      },
    },
    buf_options = { filetype = 'sqmeow-form', modifiable = false },
    win_options = { cursorline = true, wrap = false },
  })

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
      line:append(
        field.label .. (' '):rep(column - gutter - vim.fn.strdisplaywidth(field.label)),
        'SqmeowFormLabel'
      )
      line:append(shown(field, values[field.key]))
      line:render(popup.bufnr, NAMESPACE, index)
    end

    vim.bo[popup.bufnr].modifiable = false
  end

  local function focus(index)
    if vim.api.nvim_win_is_valid(popup.winid) then
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
  ---
  --- `concealcursor` covers insert mode too, so the password never appears on screen even while
  --- the person entering it is holding the keyboard.
  local function mask(winid)
    vim.wo[winid].conceallevel = 2
    vim.wo[winid].concealcursor = 'nvic'
    vim.fn.matchadd('Conceal', '.', 10, -1, { window = winid, conceal = '*' })
  end

  local edit
  edit = function(index)
    local field = fields[index]
    if not field then
      return
    end
    focus(index)

    local input = parts.Input({
      relative = { type = 'win', winid = popup.winid },
      position = { row = index - 1, col = column },
      size = { width = width - column },
      zindex = 110,
      border = { style = 'none' },
      win_options = { winhighlight = 'Normal:SqmeowFormEdit' },
    }, {
      default_value = values[field.key],
      on_submit = function(value)
        values[field.key] = value
        render()
        -- In wizard mode one answer leads to the next, which is what makes a new connection a
        -- single run of typing rather than a row of separate decisions.
        if spec.wizard and index < #fields then
          return edit(index + 1)
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
  end

  local function close()
    popup:unmount()
  end

  local function submit()
    local problem = spec.validate and spec.validate(values)
    if problem then
      popup.border:set_text('bottom', parts.Text((' %s '):format(problem), 'SqmeowError'), 'center')
      return
    end

    close()
    spec.on_submit(values)
  end

  popup:mount()
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
  map({ '<C-s>' }, submit)
  map({ 'q', '<Esc>' }, function()
    close()
    if spec.on_cancel then
      spec.on_cancel()
    end
  end)

  if spec.wizard then
    edit(1)
  end

  return true
end

--- Ask which of a list of things the user means.
---
--- A menu rather than `vim.ui.select` because this one is part of a dialog flow and should look
--- and behave like the dialog it leads to.
---
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
    return false, 'sqmeow: the connection dialog needs nui.nvim (MunifTanjim/nui.nvim)'
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
