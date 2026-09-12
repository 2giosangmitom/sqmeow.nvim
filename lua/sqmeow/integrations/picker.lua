--- One seam over every fuzzy picker.
---
--- Each picker the plugin offers is written once, against `pick`, and this module decides which
--- installed picker actually shows it. Every backend is reached through `pcall(require, ...)` at
--- call time, so none of them is a dependency, none is checked at startup, and a user with none
--- of them installed still gets a working picker through `vim.ui.select`.
---
--- A backend that raises is treated as absent. Third-party picker APIs move, and a plugin that
--- stops being able to list connections because someone else's function was renamed is worse than
--- one that quietly falls back to the built-in prompt.

local M = {}

---@class sqmeow.PickOpts
---@field prompt string Title shown above the list.
---@field format fun(item: any): string One line per item.
---@field preview nil|fun(item: any): string[] Lines shown beside the list.
---@field filetype string|nil Syntax for the preview, when there is one.
---@field on_choice fun(item: any) Called with the chosen item, and not called otherwise.
---@field empty string|nil What to say when there is nothing to show.

--- Backend names in the order `auto` tries them.
---
--- `builtin` is last and always succeeds, so the list is exhaustive by construction.
M.order = { 'telescope', 'fzf-lua', 'snacks', 'builtin' }

local function loaded(name)
  local ok, module = pcall(require, name)
  if not ok then
    return nil
  end
  return module
end

--- Each backend: whether it is installed, and how to show a list with it.
M.backends = {}

M.backends.telescope = {
  available = function()
    return loaded('telescope') ~= nil
  end,
  run = function(items, opts)
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local values = require('telescope.config').values

    local previewer
    if opts.preview then
      previewer = require('telescope.previewers').new_buffer_previewer({
        title = opts.prompt,
        define_preview = function(self, entry)
          vim.bo[self.state.bufnr].filetype = opts.filetype or 'text'
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, opts.preview(entry.value))
        end,
      })
    end

    pickers
      .new({}, {
        prompt_title = opts.prompt,
        finder = finders.new_table({
          results = items,
          entry_maker = function(item)
            local text = opts.format(item)
            return { value = item, display = text, ordinal = text }
          end,
        }),
        sorter = values.generic_sorter({}),
        previewer = previewer,
        attach_mappings = function(prompt_buf)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_buf)
            if entry then
              opts.on_choice(entry.value)
            end
          end)
          return true
        end,
      })
      :find()
  end,
}

M.backends['fzf-lua'] = {
  available = function()
    return loaded('fzf-lua') ~= nil
  end,
  run = function(items, opts)
    -- fzf matches on the line it is given, and two connections may well be labelled the same, so
    -- each line carries its index in a first field that `--with-nth` hides from the display.
    local lines = {}
    for index, item in ipairs(items) do
      lines[index] = ('%d\t%s'):format(index, opts.format(item))
    end

    local function chosen(line)
      return items[tonumber(line:match('^(%d+)\t')) or 0]
    end

    require('fzf-lua').fzf_exec(lines, {
      prompt = opts.prompt .. '> ',
      fzf_opts = { ['--delimiter'] = '\t', ['--with-nth'] = '2..' },
      preview = opts.preview and function(selected)
        local item = chosen(selected[1] or '')
        return item and table.concat(opts.preview(item), '\n') or ''
      end or nil,
      actions = {
        ['default'] = function(selected)
          local item = selected and selected[1] and chosen(selected[1])
          if item then
            opts.on_choice(item)
          end
        end,
      },
    })
  end,
}

M.backends.snacks = {
  available = function()
    local snacks = loaded('snacks')
    return snacks ~= nil and snacks.picker ~= nil
  end,
  run = function(items, opts)
    local entries = {}
    for index, item in ipairs(items) do
      entries[index] = { idx = index, text = opts.format(item), value = item }
    end

    require('snacks').picker.pick({
      title = opts.prompt,
      items = entries,
      format = 'text',
      -- Named explicitly, both branches. Left unset, snacks previews the item's `file`, and none
      -- of these lists is a list of files, so every row would report "Item has no `file`".
      preview = opts.preview and function(ctx)
        ctx.preview:reset()
        ctx.preview:set_lines(opts.preview(ctx.item.value))
        ctx.preview:highlight({ ft = opts.filetype or 'text' })
      end or 'none',
      confirm = function(picker, entry)
        picker:close()
        if entry then
          opts.on_choice(entry.value)
        end
      end,
    })
  end,
}

M.backends.builtin = {
  available = function()
    return true
  end,
  run = function(items, opts)
    vim.ui.select(items, {
      prompt = opts.prompt,
      format_item = opts.format,
    }, function(item)
      if item then
        opts.on_choice(item)
      end
    end)
  end,
}

--- Which backend a list would be shown with.
---
--- Configuring a picker that is not installed falls back rather than failing: the setting is a
--- preference, and a missing plugin is not a reason to refuse to show a list.
---
---@param preference string|nil `'auto'`, or a backend name. Defaults to the configuration.
---@return string name One of `M.order`.
function M.resolve(preference)
  preference = preference or require('sqmeow.config').get().integrations.picker

  if preference ~= 'auto' then
    local backend = M.backends[preference]
    if backend and backend.available() then
      return preference
    end
    return 'builtin'
  end

  for _, name in ipairs(M.order) do
    if M.backends[name].available() then
      return name
    end
  end
  return 'builtin'
end

--- Show a list and call back with what was chosen.
---
--- Nothing happens if the list is empty or the user cancels; a picker that pops up with no rows is
--- a worse answer than a message saying there is nothing to pick.
---
---@param items any[]
---@param opts sqmeow.PickOpts
---@return string|nil backend The backend used, or nil if there was nothing to show.
function M.pick(items, opts)
  if #items == 0 then
    vim.notify('sqmeow: ' .. (opts.empty or 'there is nothing to pick'), vim.log.levels.WARN)
    return nil
  end

  local name = M.resolve()
  local ok, err = pcall(M.backends[name].run, items, opts)
  if ok then
    return name
  end

  -- The backend is installed but did not work, which usually means its API moved. Say so once,
  -- then show the list anyway.
  vim.notify(('sqmeow: the %s picker failed (%s)'):format(name, err), vim.log.levels.WARN)
  M.backends.builtin.run(items, opts)
  return 'builtin'
end

return M
