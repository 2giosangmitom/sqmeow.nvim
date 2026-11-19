--- Draw an ERD layout as lines of text. Pure: no editor state.
---
--- Lines are kept as the directions they leave each cell in, and only turned into glyphs at
--- the end, so a crossing becomes `┼` and a branch `├` or `┬` whatever order they were
--- drawn in. Each cell also remembers what it shows, so highlights can be laid over it.

local M = {}

local strwidth = vim.api.nvim_strwidth

local bor = require('bit').bor

local UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8

--- Glyph for each set of directions. Corners are rounded.
local solid = {
  [UP] = '│',
  [DOWN] = '│',
  [UP + DOWN] = '│',
  [LEFT] = '─',
  [RIGHT] = '─',
  [LEFT + RIGHT] = '─',
  [DOWN + RIGHT] = '╭',
  [DOWN + LEFT] = '╮',
  [UP + RIGHT] = '╰',
  [UP + LEFT] = '╯',
  [UP + DOWN + RIGHT] = '├',
  [UP + DOWN + LEFT] = '┤',
  [LEFT + RIGHT + DOWN] = '┬',
  [LEFT + RIGHT + UP] = '┴',
  [UP + DOWN + LEFT + RIGHT] = '┼',
}

--- Straight runs of a dotted line; anything else falls back to solid.
local dotted = {
  [UP] = '┆',
  [DOWN] = '┆',
  [UP + DOWN] = '┆',
  [LEFT] = '┄',
  [RIGHT] = '┄',
  [LEFT + RIGHT] = '┄',
}

---@class sqmeow.ErdCanvas
---@field width integer
---@field height integer
---@field private mask table<integer, table<integer, integer>>
---@field private dots table<integer, table<integer, boolean>> False once a solid line passes.
---@field private text table<integer, table<integer, string>> `''` continues a wide character.
---@field private role table<integer, table<integer, string>>
---@field cells table<integer, { [1]: integer, [2]: integer }[]> Cells each owner drew, as `{ y, x }`.
local Canvas = {}
Canvas.__index = Canvas

---@param width integer
---@param height integer
---@return sqmeow.ErdCanvas
function M.new(width, height)
  return setmetatable({
    width = width,
    height = height,
    mask = {},
    dots = {},
    text = {},
    role = {},
    cells = {},
  }, Canvas)
end

---@param tbl table
---@param y integer
---@return table
local function row(tbl, y)
  local found = tbl[y]
  if not found then
    found = {}
    tbl[y] = found
  end
  return found
end

---@private
function Canvas:own(owner, x, y)
  if owner then
    self.cells[owner] = self.cells[owner] or {}
    table.insert(self.cells[owner], { y, x })
  end
end

---@private
function Canvas:bits(x, y, bits, is_dotted, role, owner)
  if x < 0 or y < 0 then
    return
  end
  self.width = math.max(self.width, x + 1)
  self.height = math.max(self.height, y + 1)
  local mask = row(self.mask, y)
  mask[x] = bor(mask[x] or 0, bits)
  local dots = row(self.dots, y)
  dots[x] = dots[x] ~= false and is_dotted == true
  row(self.role, y)[x] = role
  self:own(owner, x, y)
end

--- An orthogonal line from one cell to another, both included.
---@param x1 integer
---@param y1 integer
---@param x2 integer
---@param y2 integer
---@param opts { dotted: boolean|nil, role: string|nil, owner: any }|nil
function Canvas:line(x1, y1, x2, y2, opts)
  opts = opts or {}
  local role = opts.role or 'edge'
  if y1 == y2 then
    local a, b = math.min(x1, x2), math.max(x1, x2)
    if a == b then
      return self:bits(a, y1, LEFT + RIGHT, opts.dotted, role, opts.owner)
    end
    for x = a, b do
      local bits = (x > a and LEFT or 0) + (x < b and RIGHT or 0)
      self:bits(x, y1, bits, opts.dotted, role, opts.owner)
    end
  elseif x1 == x2 then
    local a, b = math.min(y1, y2), math.max(y1, y2)
    for y = a, b do
      local bits = (y > a and UP or 0) + (y < b and DOWN or 0)
      self:bits(x1, y, bits, opts.dotted, role, opts.owner)
    end
  else
    error('canvas lines are horizontal or vertical')
  end
end

--- Lines through each corner in turn.
---@param points { [1]: integer, [2]: integer }[]
---@param opts { dotted: boolean|nil, role: string|nil, owner: any }|nil
function Canvas:path(points, opts)
  for i = 2, #points do
    local a, b = points[i - 1], points[i]
    self:line(a[1], a[2], b[1], b[2], opts)
  end
end

--- Connect a cell to its neighbour on one side, as a line ending at a box border does.
---@param x integer
---@param y integer
---@param side 'left'|'right'
---@param owner any
function Canvas:join(x, y, side, owner)
  self:bits(x, y, side == 'left' and LEFT or RIGHT, false, 'edge', owner)
end

--- Text written over whatever is beneath it.
---@param x integer
---@param y integer
---@param text string
---@param role string
---@param owner any
---@return integer width Display cells written.
function Canvas:write(x, y, text, role, owner)
  local cells = row(self.text, y)
  local roles = row(self.role, y)
  local start = x
  for char in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    local w = strwidth(char)
    if w == 0 and x > start then
      -- A combining mark rides on the character before it.
      cells[x - 1] = (cells[x - 1] or '') .. char
    else
      cells[x] = char
      roles[x] = role
      self:own(owner, x, y)
      for extra = 1, w - 1 do
        cells[x + extra] = ''
        roles[x + extra] = role
      end
      x = x + math.max(w, 1)
    end
  end
  self.width = math.max(self.width, x)
  self.height = math.max(self.height, y + 1)
  return x - start
end

--- A rounded box with its title in the top border.
---@param x integer
---@param y integer
---@param w integer
---@param h integer
---@param title string
---@param owner any
---@param footer string|nil Text in the bottom border.
function Canvas:box(x, y, w, h, title, owner, footer)
  local right, bottom = x + w - 1, y + h - 1
  self:line(x, y, right, y, { role = 'border', owner = owner })
  self:line(x, bottom, right, bottom, { role = 'border', owner = owner })
  self:line(x, y, x, bottom, { role = 'border', owner = owner })
  self:line(right, y, right, bottom, { role = 'border', owner = owner })
  self:write(x + 2, y, ' ', 'border', owner)
  local width = self:write(x + 3, y, title, 'title', owner)
  self:write(x + 3 + width, y, ' ', 'border', owner)
  if footer then
    self:write(x + 2, bottom, ' ', 'border', owner)
    width = self:write(x + 3, bottom, footer, 'more', owner)
    self:write(x + 3 + width, bottom, ' ', 'border', owner)
  end
end

--- A run of cells sharing one role.
---@class sqmeow.ErdSpan
---@field row integer Zero-based line.
---@field start integer Byte column, inclusive.
---@field stop integer Byte column, exclusive.
---@field role string

---@class sqmeow.ErdPicture
---@field lines string[]
---@field spans sqmeow.ErdSpan[]
---@field bytes table<integer, integer[]> For each line, the byte column of each cell (index `x + 1`).

--- Turn the drawing into text.
---@return sqmeow.ErdPicture
function Canvas:render()
  local lines, spans, bytes = {}, {}, {}
  for y = 0, self.height - 1 do
    local parts, offsets = {}, {}
    local mask, dots = self.mask[y] or {}, self.dots[y] or {}
    local text, roles = self.text[y] or {}, self.role[y] or {}
    local length = 0
    local last = -1
    for x = 0, self.width - 1 do
      if text[x] ~= nil or mask[x] then
        last = x
      end
    end
    local run_role, run_start = nil, 0
    for x = 0, last do
      offsets[x + 1] = length
      local char = text[x]
      if char == nil then
        local bits = mask[x]
        if bits then
          char = (dots[x] and dotted[bits]) or solid[bits] or '┼'
        else
          char = ' '
        end
      end
      local role = (text[x] ~= nil or mask[x]) and roles[x] or nil
      if role ~= run_role then
        if run_role then
          table.insert(spans, { row = y, start = run_start, stop = length, role = run_role })
        end
        run_role, run_start = role, length
      end
      table.insert(parts, char)
      length = length + #char
    end
    if run_role then
      table.insert(spans, { row = y, start = run_start, stop = length, role = run_role })
    end
    offsets[last + 2] = length
    bytes[y] = offsets
    lines[y + 1] = table.concat(parts)
  end
  return { lines = lines, spans = spans, bytes = bytes }
end

--- Draw a whole layout.
---@param layout sqmeow.ErdLayout
---@return sqmeow.ErdPicture picture
---@return sqmeow.ErdCanvas canvas For the cells each edge and box owns.
function M.draw(layout)
  local canvas = M.new(layout.width, layout.height)
  for _, id in ipairs(layout.order) do
    local box = layout.boxes[id]
    local owner = 'box:' .. id
    if box.label then
      local caps = box.caps or { left = '', right = '' }
      local x = box.x + canvas:write(box.x, box.y, caps.left, 'cap', owner)
      x = x + canvas:write(x, box.y, ' ' .. box.title .. ' ', 'label', owner)
      canvas:write(x, box.y, caps.right, 'cap', owner)
    else
      canvas:box(box.x, box.y, box.w, box.h, box.title, owner, box.footer)
      for r, entry in ipairs(box.rows) do
        local x = box.x + 2
        for _, piece in ipairs(entry.pieces) do
          x = x + canvas:write(x, box.y + r, piece.text, piece.role, owner)
        end
      end
    end
  end
  for _, route in ipairs(layout.routes) do
    local owner = 'edge:' .. route.edge.id
    for _, points in ipairs(route.points) do
      canvas:path(points, { dotted = route.dotted, owner = owner })
    end
  end
  for _, point in ipairs(layout.attach) do
    canvas:join(point.x, point.y, point.side, 'edge:' .. point.edge)
  end
  for _, marker in ipairs(layout.markers) do
    canvas:write(marker.x, marker.y, marker.text, 'marker', 'edge:' .. marker.edge)
  end
  return canvas:render(), canvas
end

return M
