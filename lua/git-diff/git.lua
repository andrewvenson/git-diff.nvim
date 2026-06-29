local M = {}

local cursor_state = nil

local function detect_base_branch(cwd, callback)
	local candidates = { "origin/develop", "develop", "origin/main", "main", "origin/master", "master" }
	local idx = 1
	local function try_next()
		if idx > #candidates then
			callback(nil)
			return
		end
		local c = candidates[idx]
		idx = idx + 1
		vim.system({ "git", "-C", cwd, "rev-parse", "--verify", "--quiet", c }, { text = true }, function(obj)
			vim.schedule(function()
				if obj.code == 0 then
					callback(c)
				else
					try_next()
				end
			end)
		end)
	end
	try_next()
end

local function fetch_diff(callback, target_override)
	local cwd = vim.fn.getcwd()
	vim.system({ "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }, { text = true }, function(check)
		vim.schedule(function()
			if check.code ~= 0 then
				callback(nil, "Not inside a git repository", nil)
				return
			end

			local function with_target(target, label)
				local results = { tracked = nil, untracked = nil }
				local resolved_label = label
				local pending = 3
				local function done_inner()
					pending = pending - 1
					if pending > 0 then
						return
					end
					callback((results.tracked or "") .. (results.untracked or ""), nil, resolved_label)
				end

				vim.system({ "git", "-C", cwd, "merge-base", target, "HEAD" }, { text = true }, function(mb)
					vim.schedule(function()
						local diff_target = (mb.code == 0 and mb.stdout and mb.stdout ~= "") and vim.trim(mb.stdout)
							or target

						vim.system(
							{ "git", "-C", cwd, "log", "-1", "--format=%h%x09%s", diff_target },
							{ text = true },
							function(lg)
								vim.schedule(function()
									if lg.code == 0 and lg.stdout and lg.stdout ~= "" then
										local sha, subject = vim.trim(lg.stdout):match("^(%S+)\t(.*)$")
										if sha then
											if subject and #subject > 60 then
												subject = subject:sub(1, 57) .. "…"
											end
											if label == sha or label:sub(1, #sha) == sha then
												resolved_label = string.format('%s "%s"', sha, subject or "")
											else
												resolved_label =
													string.format('%s @ %s "%s"', label, sha, subject or "")
											end
										end
									end
									done_inner()
								end)
							end
						)

						vim.system({ "git", "-C", cwd, "diff", diff_target }, { text = true }, function(obj)
							vim.schedule(function()
								results.tracked = obj.code == 0 and (obj.stdout or "") or ""
								done_inner()
							end)
						end)
					end)
				end)

				vim.system(
					{ "git", "-C", cwd, "ls-files", "--others", "--exclude-standard" },
					{ text = true },
					function(ls)
						vim.schedule(function()
							if ls.code ~= 0 then
								results.untracked = ""
								done_inner()
								return
							end
							local untracked = {}
							for f in (ls.stdout or ""):gmatch("[^\n]+") do
								table.insert(untracked, f)
							end
							if #untracked == 0 then
								results.untracked = ""
								done_inner()
								return
							end
							local remaining = #untracked
							local chunks = {}
							for i, file in ipairs(untracked) do
								vim.system(
									{ "git", "-C", cwd, "diff", "--no-index", "--", "/dev/null", file },
									{ text = true },
									function(d)
										vim.schedule(function()
											chunks[i] = ((d.code == 0 or d.code == 1) and d.stdout and d.stdout ~= "")
													and d.stdout
												or ""
											remaining = remaining - 1
											if remaining == 0 then
												local parts = {}
												for j = 1, #untracked do
													if chunks[j] and chunks[j] ~= "" then
														table.insert(parts, chunks[j])
													end
												end
												results.untracked = table.concat(parts, "\n")
												done_inner()
											end
										end)
									end
								)
							end
						end)
					end
				)
			end

			if target_override and target_override ~= "" then
				with_target(target_override, target_override)
				return
			end

			detect_base_branch(cwd, function(base)
				if base then
					with_target(base, base)
				else
					vim.system(
						{ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" },
						{ text = true },
						function(up)
							vim.schedule(function()
								local target = up.code == 0 and vim.trim(up.stdout or "") or "HEAD"
								with_target(target, target)
							end)
						end
					)
				end
			end)
		end)
	end)
end

local function list_branches(callback)
	local cwd = vim.fn.getcwd()
	vim.system(
		{ "git", "-C", cwd, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" },
		{ text = true },
		function(obj)
			vim.schedule(function()
				if obj.code ~= 0 then
					callback({})
					return
				end
				local branches, seen = {}, {}
				for line in (obj.stdout or ""):gmatch("[^\n]+") do
					local b = vim.trim(line)
					if b ~= "" and not b:match("/HEAD$") and not seen[b] then
						seen[b] = true
						table.insert(branches, b)
					end
				end
				callback(branches)
			end)
		end
	)
end

local function pick_branch(callback)
	list_branches(function(branches)
		if #branches == 0 then
			vim.notify("No branches found", vim.log.levels.WARN)
			return
		end
		local ok, pickers = pcall(require, "telescope.pickers")
		if ok then
			local finders = require("telescope.finders")
			local conf = require("telescope.config").values
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			pickers
				.new({}, {
					prompt_title = "Diff vs branch",
					finder = finders.new_table({ results = branches }),
					sorter = conf.generic_sorter({}),
					attach_mappings = function(prompt_bufnr)
						actions.select_default:replace(function()
							local entry = action_state.get_selected_entry()
							actions.close(prompt_bufnr)
							local val = entry and (entry.value or entry[1])
							if val and val ~= "" then
								callback(val)
							end
						end)
						return true
					end,
				})
				:find()
		else
			vim.ui.select(branches, { prompt = "Diff vs branch" }, function(choice)
				if choice and choice ~= "" then
					callback(choice)
				end
			end)
		end
	end)
end

local function list_commits(callback)
	local cwd = vim.fn.getcwd()
	vim.system({
		"git",
		"-C",
		cwd,
		"log",
		"-n",
		"50",
		"--date=format:%Y-%m-%d %H:%M",
		"--pretty=format:%h\31%cd\31%cr\31%s\31%an",
	}, { text = true }, function(obj)
		vim.schedule(function()
			if obj.code ~= 0 then
				callback({})
				return
			end
			local commits = {}
			for line in (obj.stdout or ""):gmatch("[^\n]+") do
				local sha, date, age, subject, author =
					line:match("^([^\31]+)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
				if sha then
					table.insert(commits, { sha = sha, date = date, age = age, subject = subject, author = author })
				end
			end
			callback(commits)
		end)
	end)
end

local function pick_commit(callback)
	list_commits(function(commits)
		if #commits == 0 then
			vim.notify("No commits found", vim.log.levels.WARN)
			return
		end
		local function fmt(c)
			return string.format("%s  %s  %s  · %s", c.sha, c.date, c.subject, c.age)
		end
		local ok, pickers = pcall(require, "telescope.pickers")
		if ok then
			local finders = require("telescope.finders")
			local conf = require("telescope.config").values
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			pickers
				.new({}, {
					prompt_title = "Diff vs commit",
					finder = finders.new_table({
						results = commits,
						entry_maker = function(c)
							return {
								value = c.sha,
								display = fmt(c),
								ordinal = c.sha .. " " .. c.subject .. " " .. c.author,
							}
						end,
					}),
					sorter = conf.generic_sorter({}),
					attach_mappings = function(prompt_bufnr)
						actions.select_default:replace(function()
							local entry = action_state.get_selected_entry()
							actions.close(prompt_bufnr)
							if entry and entry.value then
								callback(entry.value)
							end
						end)
						return true
					end,
				})
				:find()
		else
			local items = vim.tbl_map(fmt, commits)
			vim.ui.select(items, { prompt = "Diff vs commit" }, function(_, idx)
				if idx and commits[idx] then
					callback(commits[idx].sha)
				end
			end)
		end
	end)
end

local function resolve_branch_ref(cwd, name, callback)
	vim.system(
		{ "git", "-C", cwd, "rev-parse", "--verify", "--quiet", "origin/" .. name },
		{ text = true },
		function(obj)
			vim.schedule(function()
				callback(obj.code == 0 and ("origin/" .. name) or name)
			end)
		end
	)
end

local function open(target_override)
	local viewer = require("git-diff.viewer")
	if viewer.is_open() then
		viewer.focus()
		return
	end
	vim.api.nvim_echo({ { "Loading local diff…", "Comment" } }, false, {})
	fetch_diff(function(diff, err, label)
		vim.api.nvim_echo({}, false, {})
		if err then
			vim.notify(err, vim.log.levels.WARN)
			return
		end
		if not diff or diff:gsub("%s", "") == "" then
			vim.notify("No local changes vs " .. (label or "?"), vim.log.levels.INFO)
			return
		end
		local cwd = vim.fn.getcwd()
		viewer.open(string.format("%s · local vs %s", vim.fn.fnamemodify(cwd, ":t"), label), diff, {
			cwd = cwd,
			refresh_fn = function(cb)
				fetch_diff(function(new_diff, new_err)
					cb(new_diff, new_err)
				end, target_override)
			end,
			initial_cursor = cursor_state,
			on_close = function(cur)
				cursor_state = cur
			end,
		})
	end, target_override)
end

function M.show()
	open(nil)
end

function M.show_with_prompt()
	vim.ui.select({ "develop", "main", "Branch…", "Commit…" }, { prompt = "Diff vs:" }, function(choice)
		if not choice then
			return
		end
		if choice == "develop" or choice == "main" then
			resolve_branch_ref(vim.fn.getcwd(), choice, function(target)
				open(target)
			end)
		elseif choice == "Branch…" then
			pick_branch(function(target)
				open(target)
			end)
		elseif choice == "Commit…" then
			pick_commit(function(target)
				open(target)
			end)
		end
	end)
end

return M
