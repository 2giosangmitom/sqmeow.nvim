local MiniTest = require('mini.test')
-- Staging changes against a result, without an engine.

local eq = MiniTest.expect.equality
local edit = require('sqmeow.ui.edit')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      edit.reset()
    end,
    post_case = function()
      edit.reset()
    end,
  },
})

T['counts each changed cell, deleted row and new row'] = function()
  edit.set({ row = 0 }, 1, 'a')
  edit.set({ row = 0 }, 2, vim.NIL)
  edit.toggle_delete({ { row = 4 } })
  edit.add_row()
  eq(edit.count(), 4)
  eq(edit.reset(), 4)
  eq(edit.count(), 0)
end

T['a staged value is read back, and NULL is kept apart from nothing'] = function()
  edit.set({ row = 3 }, 0, vim.NIL)
  local value, staged = edit.staged(3, 0)
  eq(value, vim.NIL)
  eq(staged, true)
  eq(select(2, edit.staged(3, 1)), false)
end

T['undo takes changes back most recent first'] = function()
  edit.set({ row = 0 }, 1, 'first')
  edit.set({ row = 0 }, 1, 'second')
  edit.add_row()

  edit.undo()
  eq(#edit.inserts(), 0)
  edit.undo()
  eq(edit.staged(0, 1), 'first')
  edit.undo()
  eq(edit.count(), 0)
  eq(edit.undo(), false)
end

T['deleting rows twice keeps them, and deleting a new row drops it'] = function()
  edit.toggle_delete({ { row = 1 }, { row = 2 } })
  eq(edit.deleted(1), true)
  edit.toggle_delete({ { row = 1 }, { row = 2 } })
  eq(edit.deleted(1), false)

  edit.add_row()
  edit.set({ insert = 1 }, 0, 'kept')
  edit.add_row()
  edit.toggle_delete({ { insert = 1 } })
  eq(#edit.inserts(), 1)
  edit.undo()
  eq(edit.inserts()[1][0], 'kept')
end

T['undo takes back a deleted row'] = function()
  edit.toggle_delete({ { row = 1 } })
  eq(edit.deleted(1), true)
  eq(edit.undo(), true)
  eq(edit.deleted(1), false)
  eq(edit.count(), 0)
end

T['a new row can start with values'] = function()
  edit.add_row({ [2] = 'copied' })
  eq(edit.changes(), {
    updates = {},
    deletes = {},
    inserts = { { { column = 2, value = 'copied' } } },
  })
end

T['changes are sent sorted, with NULL as no value'] = function()
  edit.set({ row = 5 }, 2, 'x')
  edit.set({ row = 5 }, 0, vim.NIL)
  edit.set({ row = 1 }, 1, 'y')
  edit.toggle_delete({ { row = 9 }, { row = 3 } })
  edit.add_row()
  edit.set({ insert = 1 }, 1, 'new')

  eq(edit.changes(), {
    updates = {
      { row = 1, cells = { { column = 1, value = 'y' } } },
      { row = 5, cells = { { column = 0 }, { column = 2, value = 'x' } } },
    },
    deletes = { 3, 9 },
    inserts = { { { column = 1, value = 'new' } } },
  })
end

return T
