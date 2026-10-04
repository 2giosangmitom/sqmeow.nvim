--- nvim-cmp custom source for sqmeow database metadata.

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { '.', '"', '`', '[' }
end

function source:is_available()
  local ok = pcall(require, 'sqmeow.api.connection')
  if not ok then
    return false
  end
  local conn = require('sqmeow.api.connection').target(0)
  return conn ~= nil
end

function source:complete(params, callback)
  local ok, completion = pcall(require, 'sqmeow.completion')
  if not ok then
    return callback()
  end

  local line = params.context.cursor_line
  local col = params.context.cursor.col - 1
  local items, incomplete =
    completion.items(params.context.bufnr, line, col, params.context.cursor.row)

  local cmp_kinds = require('cmp.types').lsp.CompletionItemKind

  local kind_map = {
    schema = cmp_kinds.Module,
    table = cmp_kinds.Class,
    view = cmp_kinds.Interface,
    column = cmp_kinds.Field,
  }

  local result = vim.tbl_map(function(item)
    return {
      label = item.label,
      kind = kind_map[item.kind] or cmp_kinds.Property,
      detail = item.detail,
      documentation = item.documentation and {
        kind = 'markdown',
        value = item.documentation,
      } or nil,
    }
  end, items)

  callback({ items = result, isIncomplete = incomplete })
end

function source:get_debug_name()
  return 'sqmeow'
end

return source
