local M = {}

local ns = vim.api.nvim_create_namespace 'local_diff'
local state = { left_win = nil, right_win = nil }

local function setup_hl()
  local function set(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  set('LocalDiffAdd', { bg = '#1c6630' })
  set('LocalDiffDelete', { bg = '#8a2828' })
  set('LocalDiffLineNr', { fg = '#9aa4b5' })
  set('LocalDiffLineNrAdd', { fg = '#eaffea', bold = true })
  set('LocalDiffLineNrDel', { fg = '#ffeaea', bold = true })
  set('LocalDiffNormal', { bg = '#12141c' })
  set('LocalDiffCursorLine', { bg = '#3d4570' })
  set('LocalDiffFloatBorder', { fg = '#3a3f50', bg = '#12141c' })
  set('LocalDiffOk', { fg = '#3ddc84', bold = true })
  set('LocalDiffError', { fg = '#ff5c5c', bold = true })
  set('LocalDiffAccent', { fg = '#88c0e0' })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { pattern = '*', callback = setup_hl })

local WINHIGHLIGHT = table.concat({
  'Normal:LocalDiffNormal',
  'NormalFloat:LocalDiffNormal',
  'FloatBorder:LocalDiffFloatBorder',
  'CursorLine:LocalDiffCursorLine',
}, ',')

local function show_loading(text)
  vim.api.nvim_echo({ { text, 'Comment' } }, false, {})
end

local function clear_loading()
  vim.api.nvim_echo({}, false, {})
end

local function compute_geom()
  local w = math.min(220, math.floor(vim.o.columns * 0.97))
  local h = math.min(70, math.floor(vim.o.lines * 0.94))
  local statusline = vim.o.laststatus > 0 and 1 or 0
  local avail = vim.o.lines - vim.o.cmdheight - statusline
  local total_col = math.floor((vim.o.columns - w) / 2)
  local left_content_w = 35
  local right_content_w = w - left_content_w - 4
  if right_content_w < 40 then
    left_content_w = math.max(20, w - 44)
    right_content_w = w - left_content_w - 4
  end
  return {
    total_w = w,
    height = h,
    row = math.floor((avail - h) / 2),
    total_col_start = total_col,
    left_col = total_col + 1,
    right_col = total_col + 1 + left_content_w + 2,
    left_content_w = left_content_w,
    right_content_w = right_content_w,
  }
end

local function tmux_navigate(direction)
  if not (vim.env.TMUX and vim.env.TMUX ~= '') then return end
  vim.system({ 'tmux', 'select-pane', '-' .. direction }, {}, function() end)
end

local function apply_tmux_nav_keymaps(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<C-h>', function() tmux_navigate 'L' end, o)
  vim.keymap.set('n', '<C-j>', function() tmux_navigate 'D' end, o)
  vim.keymap.set('n', '<C-k>', function() tmux_navigate 'U' end, o)
  vim.keymap.set('n', '<C-l>', function() tmux_navigate 'R' end, o)
end

local function parse_diff(diff_text)
  local lines = vim.split(diff_text or '', '\n', { plain = true })
  local files = {}
  local current
  for i, line in ipairs(lines) do
    if line:match '^diff %-%-git ' then
      if current then table.insert(files, current) end
      current = { path = line:match(' b/(.+)$') or '?', start_line = i, add = 0, del = 0 }
    elseif current then
      if not (line:match '^%+%+%+' or line:match '^%-%-%-') then
        if line:sub(1, 1) == '+' then current.add = current.add + 1
        elseif line:sub(1, 1) == '-' then current.del = current.del + 1
        end
      end
    end
  end
  if current then table.insert(files, current) end
  return files
end

local function detect_ts_lang(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  local lang = ok and ft or nil
  if lang then
    local ok2, ts_lang = pcall(vim.treesitter.language.get_lang, lang)
    if ok2 and ts_lang then lang = ts_lang end
  end
  return lang
end

local function apply_ts_highlights_blocks(buf, blocks, col_offset)
  if not (vim.treesitter and vim.treesitter.get_string_parser) then return end
  for _, block in ipairs(blocks) do
    if block.lang and #block.lines > 0 then
      local src = table.concat(vim.tbl_map(function(it) return it.content end, block.lines), '\n')
      if src ~= '' then
        local ok_lang = pcall(vim.treesitter.language.add, block.lang)
        if ok_lang then
          local ok_p, parser = pcall(vim.treesitter.get_string_parser, src, block.lang)
          if ok_p and parser then
            local trees = parser:parse()
            local tree = trees and trees[1]
            local ok_q, query = pcall(vim.treesitter.query.get, block.lang, 'highlights')
            if tree and ok_q and query then
              for id, node in query:iter_captures(tree:root(), src, 0, -1) do
                local hl = '@' .. query.captures[id] .. '.' .. block.lang
                local srow, scol, erow, ecol = node:range()
                local s_item = block.lines[srow + 1]
                local e_item = block.lines[erow + 1] or s_item
                if s_item then
                  pcall(vim.api.nvim_buf_set_extmark, buf, ns, s_item.buf_row, scol + col_offset, {
                    end_row = e_item and e_item.buf_row or s_item.buf_row,
                    end_col = ecol + col_offset,
                    hl_group = hl,
                    priority = 250,
                  })
                end
              end
            end
          end
        end
      end
    end
  end
end

local function apply_diff_language_highlights(buf, body_lines)
  local blocks = {}
  local current
  for i, line in ipairs(body_lines) do
    if line:match '^diff %-%-git ' then
      if current and #current.lines > 0 then table.insert(blocks, current) end
      local path = line:match ' b/(.+)$' or ''
      local lang = detect_ts_lang(path)
      current = lang and { lang = lang, lines = {} } or nil
    elseif line:match '^index ' or line:match '^%+%+%+' or line:match '^%-%-%-' or line:match '^@@' then
      -- skip
    elseif current then
      table.insert(current.lines, { buf_row = i - 1, content = line:sub(2) })
    end
  end
  if current and #current.lines > 0 then table.insert(blocks, current) end
  apply_ts_highlights_blocks(buf, blocks, 1)
end

local function build_file_tree(files)
  local root = { name = '', path = '', children = {}, child_map = {} }
  for _, f in ipairs(files or {}) do
    local node = root
    for i, part in ipairs(vim.split(f.path or '', '/', { plain = true })) do
      local existing = node.child_map[part]
      if not existing then
        local new_path = node.path == '' and part or (node.path .. '/' .. part)
        existing = { name = part, path = new_path, children = {}, child_map = {}, file = nil }
        node.child_map[part] = existing
        table.insert(node.children, existing)
      end
      if i == #vim.split(f.path or '', '/', { plain = true }) then existing.file = f end
      node = existing
    end
  end
  return root
end

local function flatten_file_tree(root, collapsed)
  local rows = {}
  local function walk(node, depth)
    for _, child in ipairs(node.children) do
      local is_file = child.file ~= nil
      table.insert(rows, { node = child, depth = depth, kind = is_file and 'file' or 'dir' })
      if not is_file and not collapsed[child.path] then walk(child, depth + 1) end
    end
  end
  walk(root, 0)
  return rows
end

-- opts: cwd, refresh_fn, initial_cursor, on_close
local function open_diff_window(title, body, opts)
  opts = opts or {}
  clear_loading()

  local files, body_lines, row_info, body_row_to_file, file_tree
  local collapsed_dirs = {}
  local rendered_rows = {}
  local update_diff_winbar

  local function parse_body(b)
    files = parse_diff(b)
    body_lines = vim.split(b or '', '\n', { plain = true })
    row_info = {}
    body_row_to_file = {}
    local current_file, old_l, new_l = nil, 0, 0
    local max_old, max_new = 1, 1
    for i, line in ipairs(body_lines) do
      local info = {}
      if line:match '^diff %-%-git ' then
        old_l, new_l = 0, 0
        info.is_file_header = true
        current_file = line:match ' b/(.+)$'
      elseif line:match '^index ' or line:match '^%+%+%+' or line:match '^%-%-%-' then
        -- file metadata header
      elseif line:match '^@@' then
        local o, n = line:match '^@@ %-(%d+)%S* %+(%d+)'
        old_l = (tonumber(o) or 1) - 1
        new_l = (tonumber(n) or 1) - 1
        info.bg = 'DiffChange'
      elseif line:sub(1, 1) == '+' then
        new_l = new_l + 1
        info.new = new_l
        info.bg = 'LocalDiffAdd'
      elseif line:sub(1, 1) == '-' then
        old_l = old_l + 1
        info.old = old_l
        info.bg = 'LocalDiffDelete'
      else
        old_l = old_l + 1
        new_l = new_l + 1
        info.old = old_l
        info.new = new_l
      end
      if info.old and #tostring(info.old) > max_old then max_old = #tostring(info.old) end
      if info.new and #tostring(info.new) > max_new then max_new = #tostring(info.new) end
      row_info[i] = info
      body_row_to_file[i] = current_file
    end
    row_info._max_old = max_old
    row_info._max_new = max_new
    for _, f in ipairs(files) do f._raw_start = f.start_line end
    file_tree = build_file_tree(files)
  end

  parse_body(body)

  local geom = compute_geom()

  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[right_buf].filetype = ''
  vim.bo[right_buf].buftype = 'nofile'
  vim.bo[right_buf].bufhidden = 'wipe'

  local function render_right(content_w)
    local max_old = row_info._max_old
    local max_new = row_info._max_new
    local empty_old = string.rep(' ', max_old)
    local empty_new = string.rep(' ', max_new)
    local fmt_old = '%' .. max_old .. 'd'
    local fmt_new = '%' .. max_new .. 'd'

    vim.bo[right_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(right_buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, body_lines)
    vim.bo[right_buf].modifiable = false

    for i, line in ipairs(body_lines) do
      local info = row_info[i]
      local buf_line = i - 1
      if info.is_file_header then
        local fname = line:match ' b/(.+)$' or '?'
        local label = ' ' .. fname .. ' '
        if #label > content_w - 10 then
          local visible = math.max(3, content_w - 14)
          label = ' …' .. fname:sub(#fname - visible + 1) .. ' '
        end
        local pad_total = math.max(2, content_w - #label)
        local pad_left = math.floor(pad_total / 2)
        local pad_right = pad_total - pad_left
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
          virt_lines = {
            { { '', '' } },
            { { string.rep('━', pad_left), 'NonText' }, { label, 'Title' }, { string.rep('━', pad_right), 'NonText' } },
            { { '', '' } },
          },
          virt_lines_above = true,
        })
      end
      if info.old or info.new then
        local old_s = info.old and string.format(fmt_old, info.old) or empty_old
        local new_s = info.new and string.format(fmt_new, info.new) or empty_new
        local gutter = ' ' .. old_s .. ' ' .. new_s .. ' │ '
        local nr_hl = info.bg == 'LocalDiffAdd' and 'LocalDiffLineNrAdd'
          or info.bg == 'LocalDiffDelete' and 'LocalDiffLineNrDel'
          or 'LocalDiffLineNr'
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, {
          virt_text = { { gutter, nr_hl } },
          virt_text_pos = 'inline',
        })
      end
      if info.bg then
        vim.api.nvim_buf_set_extmark(right_buf, ns, buf_line, 0, { line_hl_group = info.bg })
      end
    end

    for _, f in ipairs(files) do f.start_line = f._raw_start end
    apply_diff_language_highlights(right_buf, body_lines)
  end

  local right_win = vim.api.nvim_open_win(right_buf, false, {
    relative = 'editor',
    width = geom.right_content_w,
    height = geom.height,
    row = geom.row,
    col = geom.right_col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
    zindex = 60,
  })
  vim.wo[right_win].cursorline = true
  vim.wo[right_win].wrap = false
  vim.wo[right_win].number = false
  vim.wo[right_win].signcolumn = 'no'
  vim.wo[right_win].winhighlight = WINHIGHLIGHT
  state.right_win = right_win

  render_right(geom.right_content_w)

  if opts.initial_cursor then
    local row = math.max(1, math.min(opts.initial_cursor[1] or 1, vim.api.nvim_buf_line_count(right_buf)))
    pcall(vim.api.nvim_win_set_cursor, right_win, { row, opts.initial_cursor[2] or 0 })
  end

  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[left_buf].buftype = 'nofile'
  vim.bo[left_buf].bufhidden = 'hide'

  local function left_win_config()
    return {
      relative = 'editor', width = geom.left_content_w, height = geom.height,
      row = geom.row, col = geom.left_col, style = 'minimal', border = 'rounded',
      title = string.format(' Files (%d) ', #files), title_pos = 'center', zindex = 60,
    }
  end
  local function right_win_config_split()
    return { relative = 'editor', width = geom.right_content_w, height = geom.height, row = geom.row, col = geom.right_col }
  end
  local function right_win_config_full()
    return { relative = 'editor', width = geom.total_w - 2, height = geom.height, row = geom.row, col = geom.total_col_start + 1 }
  end

  local left_win = vim.api.nvim_open_win(left_buf, false, left_win_config())
  local function apply_left_winopts()
    vim.wo[left_win].cursorline = true
    vim.wo[left_win].wrap = false
    vim.wo[left_win].winhighlight = WINHIGHLIGHT
  end
  apply_left_winopts()
  state.left_win = left_win
  pcall(vim.api.nvim_set_current_win, right_win)

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinScrolled', 'BufWinEnter' }, {
    buffer = right_buf,
    callback = function() update_diff_winbar() end,
  })
  vim.schedule(function()
    if update_diff_winbar then update_diff_winbar() end
  end)

  local function render_left(content_w)
    rendered_rows = flatten_file_tree(file_tree, collapsed_dirs)
    local list_lines = {}
    local extmarks = {}
    for _, row in ipairs(rendered_rows) do
      local indent = string.rep('  ', row.depth)
      if row.kind == 'dir' then
        local arrow = collapsed_dirs[row.node.path] and '▸' or '▾'
        local line = indent .. arrow .. ' ' .. row.node.name .. '/'
        if vim.fn.strdisplaywidth(line) > content_w then
          line = line:sub(1, math.max(1, content_w - 1)) .. '…'
        end
        table.insert(list_lines, line)
        local lidx = #list_lines - 1
        local ac = #indent
        table.insert(extmarks, { line = lidx, col_start = ac, col_end = ac + #arrow, hl = 'LocalDiffAccent' })
        table.insert(extmarks, { line = lidx, col_start = ac + #arrow + 1, col_end = #line, hl = '@string' })
      else
        local f = row.node.file
        local add_str = '+' .. f.add
        local del_str = '-' .. f.del
        local right_chunk = add_str .. ' ' .. del_str
        local right_w = vim.fn.strdisplaywidth(right_chunk)
        local prefix = indent .. '  '
        local label = prefix .. row.node.name
        local label_max = content_w - right_w - 1
        if vim.fn.strdisplaywidth(label) > label_max and label_max > 1 then
          local keep = math.max(1, label_max - #prefix - 1)
          label = prefix .. '…' .. row.node.name:sub(math.max(1, #row.node.name - keep + 2))
        end
        local gap = math.max(1, content_w - vim.fn.strdisplaywidth(label) - right_w)
        local line = label .. string.rep(' ', gap) .. right_chunk
        table.insert(list_lines, line)
        local lidx = #list_lines - 1
        local add_start = #label + gap
        table.insert(extmarks, { line = lidx, col_start = add_start, col_end = add_start + #add_str, hl = 'LocalDiffOk' })
        table.insert(extmarks, { line = lidx, col_start = add_start + #add_str + 1, col_end = add_start + #add_str + 1 + #del_str, hl = 'LocalDiffError' })
      end
    end
    if #list_lines == 0 then list_lines = { '(no files in diff)' } end
    vim.bo[left_buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(left_buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, list_lines)
    for _, e in ipairs(extmarks) do
      pcall(vim.api.nvim_buf_set_extmark, left_buf, ns, e.line, e.col_start, { end_col = e.col_end, hl_group = e.hl })
    end
    vim.bo[left_buf].modifiable = false
  end

  render_left(geom.left_content_w)

  local closing = false
  local function persist_cursor()
    if opts.on_close and right_win and vim.api.nvim_win_is_valid(right_win) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, right_win)
      if ok then opts.on_close(cur) end
    end
  end
  local close = function()
    if closing then return end
    closing = true
    persist_cursor()
    if left_win and vim.api.nvim_win_is_valid(left_win) then pcall(vim.api.nvim_win_close, left_win, true) end
    if right_win and vim.api.nvim_win_is_valid(right_win) then pcall(vim.api.nvim_win_close, right_win, true) end
    if left_buf and vim.api.nvim_buf_is_valid(left_buf) then pcall(vim.api.nvim_buf_delete, left_buf, { force = true }) end
    if state.left_win == left_win then state.left_win = nil end
    if state.right_win == right_win then state.right_win = nil end
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(right_win),
    callback = function() vim.schedule(close) end,
  })

  local function current_file_path_in_right()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then return nil end
    local body_row = vim.api.nvim_win_get_cursor(right_win)[1]
    if body_row < 1 or body_row > #body_lines then return nil end
    return body_row_to_file[body_row]
  end

  local function expand_ancestors_of(path)
    if not path then return end
    local acc = ''
    local parts = vim.split(path, '/', { plain = true })
    for i = 1, #parts - 1 do
      acc = acc == '' and parts[i] or (acc .. '/' .. parts[i])
      collapsed_dirs[acc] = nil
    end
  end

  local function sync_left_to_path(current_path)
    if not (left_win and vim.api.nvim_win_is_valid(left_win)) or not current_path then return end
    expand_ancestors_of(current_path)
    render_left(geom.left_content_w)
    for i, r in ipairs(rendered_rows) do
      if r.kind == 'file' and r.node.file and r.node.file.path == current_path then
        pcall(vim.api.nvim_win_set_cursor, left_win, { i, 0 })
        break
      end
    end
  end

  local function toggle_files()
    local saved_cursor
    if right_win and vim.api.nvim_win_is_valid(right_win) then
      saved_cursor = vim.api.nvim_win_get_cursor(right_win)
    end
    if left_win and vim.api.nvim_win_is_valid(left_win) then
      if vim.api.nvim_get_current_win() == left_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_set_current_win(right_win)
      end
      pcall(vim.api.nvim_win_close, left_win, true)
      left_win = nil
      state.left_win = nil
      if right_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_win_set_config(right_win, right_win_config_full())
        render_right(geom.total_w - 2)
      end
    else
      local current_path = current_file_path_in_right()
      if right_win and vim.api.nvim_win_is_valid(right_win) then
        vim.api.nvim_win_set_config(right_win, right_win_config_split())
        render_right(geom.right_content_w)
      end
      if not (left_buf and vim.api.nvim_buf_is_valid(left_buf)) then return end
      left_win = vim.api.nvim_open_win(left_buf, false, left_win_config())
      apply_left_winopts()
      state.left_win = left_win
      sync_left_to_path(current_path)
      pcall(vim.api.nvim_set_current_win, left_win)
    end
    if saved_cursor and right_win and vim.api.nvim_win_is_valid(right_win) then
      local max_row = vim.api.nvim_buf_line_count(right_buf)
      saved_cursor[1] = math.max(1, math.min(saved_cursor[1], max_row))
      pcall(vim.api.nvim_win_set_cursor, right_win, saved_cursor)
    end
  end

  local function on_resize()
    geom = compute_geom()
    if left_win and vim.api.nvim_win_is_valid(left_win) then
      pcall(vim.api.nvim_win_set_config, left_win, left_win_config())
      pcall(vim.api.nvim_win_set_config, right_win, right_win_config_split())
      render_right(geom.right_content_w)
      render_left(geom.left_content_w)
    else
      pcall(vim.api.nvim_win_set_config, right_win, right_win_config_full())
      render_right(geom.total_w - 2)
    end
  end

  vim.api.nvim_create_autocmd('VimResized', { buffer = right_buf, callback = function() vim.schedule(on_resize) end })
  vim.api.nvim_create_autocmd('VimResized', { buffer = left_buf, callback = function() vim.schedule(on_resize) end })

  local function jump_right_to_file(f, focus)
    if not f or not (right_win and vim.api.nvim_win_is_valid(right_win)) then return end
    local target = f._raw_start
    for j = f._raw_start + 1, #body_lines do
      if body_lines[j]:match '^diff %-%-git ' then break end
      if body_lines[j]:match '^@@' then target = j; break end
    end
    if focus then vim.api.nvim_set_current_win(right_win) end
    vim.api.nvim_win_set_cursor(right_win, { target, 0 })
    vim.api.nvim_win_call(right_win, function()
      pcall(vim.fn.winrestview, { topline = math.max(1, f.start_line - 1) })
    end)
  end

  update_diff_winbar = function()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) then return end
    if not files or #files == 0 then vim.wo[right_win].winbar = ''; return end
    local topline = vim.api.nvim_win_call(right_win, function() return vim.fn.line 'w0' end)
    if topline < 1 then vim.wo[right_win].winbar = ''; return end
    local cur
    for _, f in ipairs(files) do
      if f._raw_start <= topline then cur = f else break end
    end
    if not cur then vim.wo[right_win].winbar = ''; return end
    local path = (cur.path or '?'):gsub('%%', '%%%%')
    vim.wo[right_win].winbar = ' %#Title# ' .. path
      .. ' %#LocalDiffOk#+' .. cur.add
      .. ' %#LocalDiffError#-' .. cur.del
      .. ' %#Normal#'
  end

  local function file_idx_for_buf_row(buf_row)
    local body_row = buf_row + 1
    if body_row < 1 then return nil end
    local idx
    for i, f in ipairs(files) do
      if f._raw_start <= body_row then idx = i else break end
    end
    return idx
  end

  local function next_file()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) or #files == 0 then return end
    local idx = file_idx_for_buf_row(vim.api.nvim_win_get_cursor(right_win)[1] - 1) or 0
    local target = math.min(idx + 1, #files)
    if target ~= idx then jump_right_to_file(files[target], false) end
  end

  local function prev_file()
    if not (right_win and vim.api.nvim_win_is_valid(right_win)) or #files == 0 then return end
    local idx = file_idx_for_buf_row(vim.api.nvim_win_get_cursor(right_win)[1] - 1) or (#files + 1)
    local target = math.max(1, idx - 1)
    if target ~= idx then jump_right_to_file(files[target], false) end
  end

  local function jump_to_file()
    if not left_win or not vim.api.nvim_win_is_valid(left_win) then return end
    local row = rendered_rows[vim.api.nvim_win_get_cursor(left_win)[1]]
    if not row then return end
    if row.kind == 'dir' then
      collapsed_dirs[row.node.path] = not collapsed_dirs[row.node.path] or nil
      local target_path = row.node.path
      render_left(geom.left_content_w)
      for i, r in ipairs(rendered_rows) do
        if r.node.path == target_path then pcall(vim.api.nvim_win_set_cursor, left_win, { i, 0 }); break end
      end
      return
    end
    jump_right_to_file(row.node.file, true)
  end

  local refreshing = false
  local function refresh()
    if not opts.refresh_fn or refreshing then return end
    refreshing = true
    show_loading 'Refreshing diff…'
    opts.refresh_fn(function(new_body, err)
      refreshing = false
      clear_loading()
      if err then vim.notify('Refresh failed: ' .. err, vim.log.levels.ERROR); return end
      if not new_body or new_body:gsub('%s', '') == '' then
        vim.notify('No local changes', vim.log.levels.INFO)
        return
      end
      parse_body(new_body)
      local content_w = (left_win and vim.api.nvim_win_is_valid(left_win)) and geom.right_content_w or (geom.total_w - 2)
      render_right(content_w)
      if left_win and vim.api.nvim_win_is_valid(left_win) then
        pcall(vim.api.nvim_win_set_config, left_win, left_win_config())
        render_left(geom.left_content_w)
      end
    end)
  end

  local function open_at_cursor()
    if not opts.cwd or not (right_win and vim.api.nvim_win_is_valid(right_win)) then return end
    local body_row = vim.api.nvim_win_get_cursor(right_win)[1]
    if body_row < 1 or body_row > #body_lines then return end
    local info = row_info[body_row]
    local file = body_row_to_file[body_row]
    if not file then return end
    local line_num = (info and (info.new or info.old)) or 1
    close()
    vim.schedule(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(opts.cwd .. '/' .. file))
      pcall(vim.api.nvim_win_set_cursor, 0, { line_num, 0 })
      vim.cmd 'normal! zz'
    end)
  end

  local lo = { buffer = left_buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(left_buf)
  vim.keymap.set('n', 'q', close, lo)
  vim.keymap.set('n', '<Esc>', close, lo)
  vim.keymap.set('n', '<CR>', jump_to_file, lo)
  vim.keymap.set('n', '\\', toggle_files, lo)
  if opts.refresh_fn then vim.keymap.set('n', 'r', refresh, lo) end
  vim.keymap.set('n', '<Tab>', function()
    if vim.api.nvim_win_is_valid(right_win) then vim.api.nvim_set_current_win(right_win) end
  end, lo)

  local ro = { buffer = right_buf, nowait = true, silent = true }
  apply_tmux_nav_keymaps(right_buf)
  vim.keymap.set('n', 'q', close, ro)
  vim.keymap.set('n', '<Esc>', close, ro)
  vim.keymap.set('n', '\\', toggle_files, ro)
  vim.keymap.set('n', '}', next_file, ro)
  vim.keymap.set('n', '{', prev_file, ro)
  if opts.refresh_fn then vim.keymap.set('n', 'r', refresh, ro) end
  if opts.cwd then vim.keymap.set('n', '<CR>', open_at_cursor, ro) end
  vim.keymap.set('n', '<Tab>', function()
    if not left_win or not vim.api.nvim_win_is_valid(left_win) then
      toggle_files()
      if left_win and vim.api.nvim_win_is_valid(left_win) then vim.api.nvim_set_current_win(left_win) end
    else
      sync_left_to_path(current_file_path_in_right())
      vim.api.nvim_set_current_win(left_win)
    end
  end, ro)
end

function M.open(title, body, opts)
  open_diff_window(title, body, opts)
end

function M.is_open()
  return (state.left_win and vim.api.nvim_win_is_valid(state.left_win))
    or (state.right_win and vim.api.nvim_win_is_valid(state.right_win))
end

function M.focus()
  if state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
    vim.api.nvim_set_current_win(state.left_win)
    return true
  end
  if state.right_win and vim.api.nvim_win_is_valid(state.right_win) then
    vim.api.nvim_set_current_win(state.right_win)
    return true
  end
  return false
end

return M
