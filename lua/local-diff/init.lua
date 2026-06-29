local M = {}

function M.setup(opts)
  opts = opts or {}

  vim.keymap.set('n', '<leader>gd', function()
    require('local-diff.git').show()
  end, { desc = '[G]it local [D]iff (vs base branch)' })

  vim.keymap.set('n', '<leader>gD', function()
    require('local-diff.git').show_with_prompt()
  end, { desc = '[G]it local [D]iff vs custom branch/commit' })
end

return M
