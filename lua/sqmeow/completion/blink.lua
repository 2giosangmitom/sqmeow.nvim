--- blink.cmp source provider for sqmeow database metadata.

---@class sqmeow.BlinkSource
local Source = {}

function Source.new()
  return setmetatable({}, { __index = Source })
end

function Source:get_trigger_characters()
  return { '.', '"', '`', '[' }
end

function Source:enabled()
  local ok = pcall(require, 'sqmeow.api.connection')
  if not ok then
    return false
  end
  local conn = require('sqmeow.api.connection').target(0)
  return conn ~= nil
end

function Source:get_completions(context, callback)
  local ok, completion = pcall(require, 'sqmeow.completion')
  if not ok then
    return callback({ is_incomplete_backward = false, is_incomplete_forward = false, items = {} })
  end

  local line = context.line
  local col = context.cursor[2]
  local items, incomplete = completion.items(context.bufnr, line, col, context.cursor[1])

  local blink_kinds = require('blink.cmp.types').CompletionItemKind

  local kind_map = {
    schema = blink_kinds.Module,
    table = blink_kinds.Class,
    view = blink_kinds.Interface,
    column = blink_kinds.Field,
  }

  local result = vim.tbl_map(function(item)
    return {
      label = item.label,
      kind = kind_map[item.kind] or blink_kinds.Property,
      detail = item.detail,
      documentation = item.documentation and {
        kind = 'markdown',
        value = item.documentation,
      } or nil,
    }
  end, items)

  callback({
    items = result,
    is_incomplete_backward = incomplete,
    is_incomplete_forward = incomplete,
  })
end

return Source
