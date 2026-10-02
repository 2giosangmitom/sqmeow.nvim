-- SQL context from Neovim's Tree-sitter API (derekstride/tree-sitter-sql).
local M = {}

local references = [[
  (relation (object_reference) @reference)
  (from (object_reference) @reference)
  (insert (object_reference) @reference)
  (ERROR (keyword_insert) (keyword_into) (object_reference) @reference)
  ";" @boundary
]]

local function unquote(text)
  local first, last = text:sub(1, 1), text:sub(-1)
  if (first == '"' or first == '`') and last == first then
    return (text:sub(2, -2):gsub(first .. first, first))
  elseif first == '[' and last == ']' then
    return (text:sub(2, -2):gsub(']]', ']'))
  end
  return text
end

-- A trailing dot is often an ERROR node while typing; only this unfinished suffix
-- needs a pattern. Statements, relations, aliases, strings and comments use the tree.
local identifier = [=[\%("[^"]*"\|`[^`]*`\|\[[^]]*\]\|[[:alnum:]_$]\+\)]=]
local function qualifier(prefix)
  local match = vim.fn.matchlist(
    prefix,
    [[\%(\(]] .. identifier .. [[\)\.\)\?\(]] .. identifier .. [[\)\.[[:alnum:]_$]*$]]
  )
  if #match > 0 then
    return unquote(match[3]), match[2] ~= '' and unquote(match[2]) or nil
  end
end

--- col is a zero-based byte offset; row is an optional one-based buffer row.
function M.read(bufnr, line, col, row)
  local name, schema = qualifier(line:sub(1, col))
  local source = row and bufnr or line
  local ok, parser = pcall(function()
    return row and vim.treesitter.get_parser(bufnr, 'sql')
      or vim.treesitter.get_string_parser(line, 'sql')
  end)
  -- The SQL parser is optional: metadata and explicit table qualifiers still work.
  if not ok or not parser then
    return {}, name, schema
  end
  local trees = parser:parse()
  if not trees[1] then
    return {}, name, schema
  end
  local root = trees[1]:root()
  local offset = row and (vim.api.nvim_buf_get_offset(bufnr, row - 1) + col) or col
  local query = vim.treesitter.query.parse('sql', references)
  local lower, upper, objects = 0, math.huge, {}
  for id, node in query:iter_captures(root, source) do
    local _, _, start = node:start()
    if query.captures[id] == 'boundary' then
      if start < offset then
        lower = start + 1
      else
        upper = math.min(upper, start)
      end
    else
      table.insert(objects, node)
    end
  end
  local function field(node, key)
    local child = node:field(key)[1]
    return child and unquote(vim.treesitter.get_node_text(child, source)) or nil
  end
  local refs = {}
  for _, node in ipairs(objects) do
    local _, _, start = node:start()
    if start >= lower and start < upper then
      table.insert(refs, {
        name = field(node, 'name'),
        schema = field(node, 'schema'),
        alias = field(node:parent(), 'alias'),
      })
    end
  end
  return refs, name, schema
end

return M
