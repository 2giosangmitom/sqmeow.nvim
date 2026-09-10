--- Writing SQL that names things.
---
--- Quoting is per dialect, and getting it wrong is not cosmetic: an unquoted name that happens to
--- be a reserved word, or that has a capital letter in PostgreSQL, refers to something else or to
--- nothing at all.

local M = {}

--- Quote one identifier for a dialect.
---
---@param dialect string|nil 'mysql' uses backticks; everything else uses double quotes.
---@param name string
---@return string
function M.quote(dialect, name)
  if dialect == 'mysql' then
    return '`' .. name:gsub('`', '``') .. '`'
  end
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Join name parts into a qualified name.
---
---@param dialect string|nil
---@param parts string[] Such as `{ 'public', 'users' }`.
---@return string
function M.qualify(dialect, parts)
  return table.concat(
    vim.tbl_map(function(part)
      return M.quote(dialect, part)
    end, parts),
    '.'
  )
end

--- A `SELECT` over a relation.
---
--- The limit is there because a drawer action should never be the thing that pulls a hundred
--- million rows across a network.
---
---@param dialect string|nil
---@param parts string[]
---@param limit integer
---@return string
function M.select_from(dialect, parts, limit)
  return ('select * from %s limit %d'):format(M.qualify(dialect, parts), limit)
end

return M
