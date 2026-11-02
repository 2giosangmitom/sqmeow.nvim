-- SQL context from Neovim's Tree-sitter API (derekstride/tree-sitter-sql).
local M = {}

--- Whether Neovim can parse SQL, which table aliases need.
---@return boolean
function M.available()
  local ok, parser = pcall(function()
    return vim.treesitter.get_string_parser('select 1', 'sql')
  end)
  return ok and parser ~= nil
end

local references = [[
  (relation (object_reference) @reference)
  (from (object_reference) @reference)
  (insert (object_reference) @reference)
  (ERROR (keyword_insert) (keyword_into) (object_reference) @reference)
  ";" @boundary
]]

--- Strip identifier quotes and unescape doubled delimiters.
---@param text string
---@return string
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
local identifier =
  [=[\%("\%([^"]\|""\)*"\|`\%([^`]\|``\)*`\|\[\%([^]]\|]]\)*\]\|[[:alnum:]_$]\+\)]=]
local tail = [=[\%("\%([^"]\|""\)*\|`\%([^`]\|``\)*\|\[\%([^]]\|]]\)*\|[[:alnum:]_$]*\)]=]

--- `schema.relation.` or `relation.` before the cursor, allowing an unfinished quoted tail.
---@param prefix string
---@return string|nil name
---@return string|nil schema
local function qualifier(prefix)
  local match = vim.fn.matchlist(
    prefix,
    [[\%(\(]] .. identifier .. [[\)\.\)\?\(]] .. identifier .. [[\)\.]] .. tail .. [[$]]
  )
  if #match > 0 then
    return unquote(match[3]), match[2] ~= '' and unquote(match[2]) or nil
  end
end

--- Relations bound to the buffer or named by a `[Preview: ...]` buffer.
---@param bufnr integer|nil
---@param qualifier_schema string|nil
---@return table[]
local function buffer_refs(bufnr, qualifier_schema)
  -- An explicitly typed schema takes precedence over the buffer's relation.
  if qualifier_schema or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local bound = vim.b[bufnr].sqmeow_relation
  if bound then
    if type(bound) == 'string' then
      return { { name = bound } }
    elseif type(bound) == 'table' then
      return { { name = bound.name, schema = bound.schema } }
    end
  end
  local bname = vim.api.nvim_buf_get_name(bufnr)
  local preview_name = bname:match('%[Preview:%s*([^%s%(%]]+)')
  if preview_name then
    return { { name = preview_name } }
  end
  return {}
end

--- Relations the tree names in the statement around `offset`.
---@param parser any A `vim.treesitter.LanguageTree` from `get_parser` or `get_string_parser`.
---@param source integer|string Buffer handle or the parsed text.
---@param offset integer Zero-based byte offset of the cursor in `source`.
---@return table[]|nil refs Nil when the parser produced no tree.
local function collect(parser, source, offset)
  local trees = parser:parse()
  if not trees[1] then
    return nil
  end
  local root = trees[1]:root()
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
  return refs
end

--- The whole text of a buffer, matching `nvim_buf_get_offset` positions.
---@param bufnr integer
---@return string
local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

--- The identifier quote left open at the end of `prefix`, skipping string literals.
---@param prefix string
---@return integer|nil start One-based byte index of the opening delimiter.
---@return string|nil open
function M.open_quote(prefix)
  local start, open, close
  local i = 1
  while i <= #prefix do
    local ch = prefix:sub(i, i)
    if close then
      if ch == close then
        if prefix:sub(i + 1, i + 1) == close then
          i = i + 1
        else
          start, open, close = nil, nil, nil
        end
      end
    elseif ch == "'" then
      -- `''` inside a literal closes and reopens it, which leaves the scan in the same state.
      local stop = prefix:find("'", i + 1, true)
      i = stop or #prefix
    elseif ch:match('["`%[]') and prefix:sub(i - 1, i - 1):match('^[%s%.,%(=<>!+%-/*;]?$') then
      start, open, close = i, ch, ch == '[' and ']' or ch
    end
    i = i + 1
  end
  return start, open
end

--- col is a zero-based byte offset; row is an optional one-based buffer row.
---@param bufnr integer
---@param line string
---@param col integer
---@param row integer|nil
---@return table[] refs Relations the statement names, with their aliases.
---@return string|nil name Qualifier before the cursor.
---@return string|nil schema Schema qualifier before the cursor.
---@return boolean parsed Whether a Tree-sitter tree answered the request.
function M.read(bufnr, line, col, row)
  local name, schema = qualifier(line:sub(1, col))
  local offset = row and (vim.api.nvim_buf_get_offset(bufnr, row - 1) + col) or col
  local ok, parser = pcall(function()
    return row and vim.treesitter.get_parser(bufnr, 'sql')
      or vim.treesitter.get_string_parser(line, 'sql')
  end)
  local parsed = false
  if ok and parser then
    local refs = collect(parser, row and bufnr or line, offset)
    parsed = refs ~= nil
    if refs and #refs > 0 then
      return refs, name, schema, true
    end
  end

  -- An open qualifier dot makes the grammar swallow the FROM that follows, as in
  -- `SELECT t.` on one line and `FROM users t` on the next. Reparse a copy with
  -- every such dot completed; one byte replaces another, so offsets still line up.
  if name and line:sub(col, col) == '.' then
    local text = line
    if row and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      text = buffer_text(bufnr)
    end
    local fixed = text:gsub('%.(%s)', '_%1'):gsub('%.$', '_')
    if fixed ~= text then
      local retry_ok, retry = pcall(function()
        return vim.treesitter.get_string_parser(fixed, 'sql')
      end)
      if retry_ok and retry then
        local refs = collect(retry, fixed, offset)
        if refs and #refs > 0 then
          return refs, name, schema, true
        end
      end
    end
  end

  -- The SQL parser is optional: metadata and explicit table qualifiers still work.
  return buffer_refs(bufnr, schema), name, schema, parsed
end

return M
