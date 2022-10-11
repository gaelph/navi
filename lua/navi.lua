--- @alias Callback function
--- @alias Number function
local hlns = vim.api.nvim_create_namespace("navi:hl")

local M = {
	repo = {},
	mode = {},
	yanks = {},
	yank_register = '"',
}

function M.set_mode(mode)
	M.mode = mode
end

function M.yank_set_register(register)
	local paths = {}
	for _, yank in ipairs(vim.tbl_values(M.yanks)) do
		if yank.register == register then
			table.insert(paths, yank.path)
		end
	end
	if register == "+" or register == "*" then
		register = '"'
	end

	print("setting register", register, "with", vim.inspect(paths))
	vim.fn.setreg(register, paths)
end

function M.add_yank(line, path, register)
	print("add yank of line", line, ":", path, "to register", register)
	local buffer = vim.api.nvim_get_current_buf()

	M.yanks[line] = {
		path = path,
		buffer = buffer,
		mode = M.mode,
		register = register,
	}

	M.yank_set_register(register)
end

local State = {}

function State:new(cwd)
	local o = {
		mode = "rename",
		inserting = false,
		rendering = false,
		win = nil,
		buf = nil,
		cwd = cwd,
		files = {
			{ name = "..", type = "directory" },
			{ name = ".", type = "directory" },
		},
		changes = {},
	}
	self._index = self
	setmetatable(o, self)

	return o
end

local group = vim.api.nvim_create_augroup("NAVI", {})
vim.api.nvim_create_autocmd("FileType", {
	pattern = "NAVI",
	group = group,
	callback = function()
		local state = State:new(vim.fn.getcwd())
		local buf = vim.api.nvim_get_current_buf()
		state.buf = buf

		M.repo[buf] = state

		M.set_keymaps(state)
		M.attach_listeners(state)
	end,
})

--[[ vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, { ]]
--[[ 	pattern = "navi:/*", ]]
--[[ 	group = group, ]]
--[[ 	callback = function(arg) ]]
--[[ 		local buf = arg.buf ]]
--[[ 		local state = M.repo[buf] ]]
--[[]]
--[[ 		if state.last_pos ~= nil then ]]
--[[ 			vim.api.nvim_win_set_cursor(state.win, state.last_pos) ]]
--[[ 		end ]]
--[[ 	end, ]]
--[[ }) ]]

vim.api.nvim_create_autocmd("CursorMoved", {
	pattern = "navi:/*",
	group = group,
	callback = function(arg)
		local buf = arg.buf
		local state = M.repo[buf]

		local pos = vim.api.nvim_win_get_cursor(0)
		state.last_pos = pos
	end,
})

local function get_name(path)
	path = string.sub(path, 1, -2)
	return string.format("navi:/%s", path)
end

local function on_dir_changed(cwd, buf)
	local buffer = buf and buf or vim.api.nvim_get_current_buf()

	if not M.repo[buffer] then
		return
	end
	local state = M.repo[buffer]

	state.cwd = cwd
	state.files = M.readdir(cwd)

	M.render(state)
end

local function start_browse(path, target_window)
	local buf = M.create_buffer(path)
	local win = nil

	if target_window == "self" then
		win = vim.api.nvim_get_current_win()
	else
		win = M.create_window(target_window)
	end

	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_current_buf(buf)

	on_dir_changed(path, buf)
end

vim.api.nvim_create_user_command("Navi", function(arg)
	local path = arg.args
	if path == "" then
		---@diagnostic disable-next-line
		path = vim.fs.dirname(vim.fn.expand("%")) .. "/"
	end

	path = vim.fn.simplify(vim.fn.getcwd() .. "/" .. path)
	start_browse(path, "vsplit")
end, { force = true })

local function highlight(state)
	for line, node in ipairs(state.files) do
		if node.type == "directory" then
			vim.api.nvim_buf_add_highlight(
				0,
				hlns,
				"Salient",
				line - 1,
				0,
				#node.name + 1
			)
		end
	end

	for line, yank in pairs(M.yanks) do
		local path = yank.path
		if yank.buffer ~= state.buf then
			goto continue
		end
		local hl = yank.mode == "move" and "Faded" or "Bold"

		vim.api.nvim_buf_add_highlight(0, hlns, hl, line, 0, #path + 1)
		::continue::
	end
end

local function Line(props)
	local file = props.file

	if file.type == "directory" then
		return string.format("%s/", file.name)
	else
		return file.name
	end
end

local function clear(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
end

function M.render(state, reset_cursor)
	local current_buffer = vim.api.nvim_get_current_buf()
	if state.buf ~= current_buffer then
		return
	end

	state.rendering = true
	local buf = state.buf
	local win = state.win or 0
	local pos = reset_cursor and { 1, 0 } or vim.api.nvim_win_get_cursor(win)

	clear(buf)

	local lines = {}
	for _, node in ipairs(state.files) do
		local line = Line({ file = node })
		table.insert(lines, line)
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	highlight(state)

	if pos[1] > #lines then
		pos[1] = #lines
	end
	local l = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1], false)
	if #l == 0 then
		pos[2] = 0
	else
		local line = l[1]
		if #line < pos[2] then
			pos[2] = #line - 1
		end
	end

	vim.api.nvim_win_set_cursor(win, pos)
	state.rendering = false
end

function _G.navi_yank_motion(arg)
	local state = M.repo[vim.api.nvim_get_current_buf()]

	if arg == "line" then
		local line_number_start = vim.fn.getpos("'[")[2]
		local line_number_end = vim.fn.getpos("']")[2]

		for i = line_number_start - 1, line_number_end - 1 do
			local path = state.cwd .. "/" .. state.files[i].name
			M.add_yank(i, path, M.yank_register)
		end

		M.render(state)
	else
		local pos_start = vim.fn.getpos("'[")
		local pos_end = vim.fn.getpos("']")
		local content = vim.api.nvim_buf_get_text(
			state.buf,
			pos_start[2] - 1,
			pos_start[3] - 1,
			pos_end[2] - 1,
			pos_end[3],
			{}
		)
		vim.fn.setreg(M.yank_register, content)
	end
end

function State:set_mode(mode)
	self.mode = mode
end

function M.readdir(path)
	local files = {
		{ name = "..", type = "directory" },
		{ name = ".", type = "directory" },
	}

	local success, error = pcall(function()
		for file, type in vim.fs.dir(path) do
			table.insert(files, { name = file, type = type })
		end

		table.sort(files, function(a, b)
			if a.type ~= b.type then
				if a.type == "directory" then
					return true
				end
			else
				return a.name < b.name
			end
		end)
	end)

	if not success then
		print(vim.inspect(error))
		return {}
	end

	return files
end

function M.change_dir(dirpath)
	on_dir_changed(dirpath, 0)
end

local function edit_file(base, filename)
	local path = vim.fn.simplify(base .. "/" .. filename)
	vim.cmd(string.format("e %s", path))
end

local function get_buffer(name)
	local buffers = vim.api.nvim_list_bufs()
	local oname = name
	for _, buffer in ipairs(buffers) do
		local bname = vim.api.nvim_buf_get_name(buffer)
		if bname == oname then
			return buffer
		end
	end

	return nil
end

function M.create_buffer(cwd)
	if cwd == nil then
		cwd = vim.fn.getcwd()
	end

	local name = get_name(cwd)
	local buf = get_buffer(name)

	if buf == nil then
		buf = vim.api.nvim_create_buf(true, true)

		vim.api.nvim_buf_set_option(buf, "filetype", "NAVI")
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "buflisted", false)
		vim.api.nvim_buf_set_name(buf, name)
	end

	return buf
end

function M.set_keymaps(state)
	local buf = state.buf

	vim.keymap.set("n", "-", function()
		local c = string.sub(state.cwd, 1, -2)
		local parent = vim.fs.dirname(c) .. "/"
		print("[LS] parent: " .. vim.inspect(parent))
		vim.cmd("m'")
		start_browse(parent, "self")
	end, { buffer = buf })

	vim.keymap.set("i", "<cr>", "", { buffer = buf })
	vim.keymap.set("n", "<cr>", function()
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local c = vim.api.nvim_buf_get_lines(0, line - 1, line, false)
		if #c == 0 then
			return
		end
		local file_or_dir_name = c[1]

		vim.cmd("m'")
		if vim.endswith(file_or_dir_name, "/") then
			local to = vim.fn.simplify(state.cwd .. "/" .. file_or_dir_name)
			start_browse(to, "self")
		else
			edit_file(state.cwd, file_or_dir_name)
		end
	end, { buffer = buf })

	return buf
end

function M.create_window(split)
	if split ~= nil then
		vim.cmd(split)
	end

	local win = vim.api.nvim_get_current_win()

	return win
end

--- Debounces a function on the trailing edge. Automatically
--- `schedule_wrap()`s.
---
--@param fn (function) Function to debounce
--@param timeout (number) Timeout in ms
--@param first (boolean, optional) Whether to use the arguments of the first
---call to `fn` within the timeframe. Default: Use arguments of the last call.
--@returns (function, timer) Debounced function and timer. Remember to call
---`timer:close()` at the end or you will leak memory!
local function debounce_trailing(fn, ms, first)
	local timer = vim.loop.new_timer()
	local wrapped_fn

	if not first then
		function wrapped_fn(...)
			local argv = { ... }
			local argc = select("#", ...)

			timer:start(ms, 0, function()
				pcall(vim.schedule_wrap(fn), unpack(argv, 1, argc))
			end)
		end
	else
		local argv, argc
		function wrapped_fn(...)
			argv = argv or { ... }
			argc = argc or select("#", ...)

			timer:start(ms, 0, function()
				pcall(vim.schedule_wrap(fn), unpack(argv, 1, argc))
			end)
		end
	end
	return wrapped_fn, timer
end

function State:add_change(line, change)
	self.changes[line] = change
end

local function rename_file(state, change)
	local old_path = vim.fn.simplify(state.cwd .. "/" .. change.old)
	local new_path = vim.fn.simplify(state.cwd .. "/" .. change.new)

	if old_path == new_path then
		return
	end

	io.popen(string.format("mv %s %s", old_path, new_path))
end

local function create_file(state, filename)
	if filename == "" then
		return
	end

	local path = state.cwd .. "/" .. filename
	path = vim.fn.simplify(path)

	io.popen(string.format("touch %s", path))
end

local function copy_file(source, destination)
	local flag = ""
	source = vim.fn.simplify(source)
	destination = vim.fn.simplify(destination)

	if vim.endswith(source, "/") then
		flag = "-R"
	end

	io.popen(string.format("cp %s %s %s", flag, source, destination))
end

local function move_file(source, destination)
	source = vim.fn.simplify(source)
	destination = vim.fn.simplify(destination)

	io.popen(string.format("mv %s %s", source, destination))
end

local function create_directory(state, dirname)
	local path = state.cwd .. "/" .. string.sub(dirname, 0, -2)
	path = vim.fn.simplify(path)

	io.popen(string.format("mkdir %s", path))
end

local function remove_file(state, filename)
	if filename == "" then
		return
	end

	filename = vim.fn.simplify(filename)

	local flag = ""
	if vim.endswith(filename, "/") then
		flag = "-rf"
	end

	if
		vim.fn.confirm(
			string.format("Confirm deletion of %s?", filename),
			"&Yes\n&No",
			1
		) == 1
	then
		local path = state.cwd .. "/" .. filename
		io.popen(string.format("rm %s %s", flag, path))
	end
end

function State:apply_changes()
	if self.inserting then
		return
	end

	for _, change in pairs(self.changes) do
		if
			change.mode == "rename"
			and change.old ~= nil
			and change.new ~= nil
		then
			rename_file(self, change)
		end

		if change.mode == "touch" and change.new ~= nil then
			if vim.endswith(change.new, "/") then
				create_directory(self, change.new)
			else
				create_file(self, change.new)
			end
		end

		if change.mode == "rm" then
			remove_file(self, change.old)
		end
	end

	self.changes = {}

	vim.defer_fn(function()
		self.files = M.readdir(self.cwd)
		M.render(self)
		State.set_mode(self, "rename")
	end, 50)
end

local function listener(state, first_line, last_line, last_line_updated)
	if state.rendering then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local start = first_line + 1
	local last = last_line_updated < last_line and last_line
		or last_line_updated

	for i = start, last do
		local old = nil
		local new = nil
		local line = i

		old = state.files[i] and state.files[i].name or nil
		new = lines[line] and lines[line] or nil

		if old and state.files[i].type == "directory" then
			old = old .. "/"
		end

		local change = {
			mode = state.mode,
			line = line,
			old = old,
			new = new,
		}

		State.add_change(state, i, change)
		-- State.add_change(state, i, change)
	end

	if state.mode == "rm" then
		State.set_mode(state, "rename")
	end

	local apply = function()
		State.apply_changes(state)
	end

	vim.defer_fn(apply, 50)
end

local function get_visual_selection_range()
	local line_v, column_v = unpack(vim.fn.getpos("v"), 2, 3)
	local line_cur, column_cur = unpack(vim.api.nvim_win_get_cursor(0))
	column_cur = column_cur + 1
	-- backwards visual selection
	if line_v > line_cur or (line_v == line_cur and column_cur < column_v) then
		return line_cur, column_cur, line_v, column_v
	end
	return line_v, column_v, line_cur, column_cur
end

function M.attach_listeners(state)
	local l = debounce_trailing(listener, 100)
	vim.api.nvim_buf_attach(0, false, {
		on_lines = function(_, _, _, first_line, last_line, last_line_updated)
			if state.rendering then
				return
			end
			l(state, first_line, last_line, last_line_updated)
		end,
	})

	vim.keymap.set("n", "i", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("i", true, false, true) --[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0, noremap = true })
	vim.keymap.set("n", "I", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("I", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "s", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("s", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0, noremap = true })
	vim.keymap.set("n", "S", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("S", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "a", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("a", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })
	vim.keymap.set("n", "A", function()
		State.set_mode(state, "rename")
		local keys = vim.api.nvim_replace_termcodes("A", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "o", function()
		State.set_mode(state, "touch")
		local keys = vim.api.nvim_replace_termcodes("o", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "O", function()
		State.set_mode(state, "touch")
		local keys = vim.api.nvim_replace_termcodes("O", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "dd", function()
		State.set_mode(state, "rm")
		local count = vim.v.count1
		local k = string.format("%ddd", count)
		local keys = vim.api.nvim_replace_termcodes(k, true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "n", true)
	end, { buffer = 0 })

	vim.keymap.set("x", "d", function()
		State.set_mode(state, "none")
		local line_start, _, line_end, _ = get_visual_selection_range()
		local lines =
			vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false)

		for i, line in ipairs(lines) do
			local change = {
				mode = "rm",
				old = line,
			}
			State.add_change(state, line_start + i, change)
		end

		State.apply_changes(state)
		local keys = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "x", true)
		State.set_mode(state, "rename")
	end, { buffer = 0 })

	vim.keymap.set("n", "y", function()
		M.set_mode("copy")
		M.yank_register = vim.v.register
		vim.api.nvim_set_option("operatorfunc", "v:lua.navi_yank_motion")
		return "g@"
	end, {
		buffer = 0,
		silent = true,
		expr = true,
		noremap = true,
	})

	vim.keymap.set("x", "y", function()
		M.set_mode("copy")
		local line_start, _, line_end, _ = get_visual_selection_range()
		local lines = vim.api.nvim_buf_get_lines(
			state.buf,
			line_start - 1,
			line_end,
			false
		)

		for i, line in ipairs(lines) do
			local yank = {
				line = i + line_start - 2,
				path = state.cwd .. "/" .. line,
			}
			M.add_yank(yank.line, yank.path, vim.v.register)
		end

		M.render(state)
		local keys = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "x", true)
	end, { buffer = state.buf })

	vim.keymap.set("n", "yy", function()
		M.set_mode("copy")
		local count = vim.v.count
		local pos = vim.api.nvim_win_get_cursor(0)
		local initial = pos[1] - 1
		local last = initial + count + 1
		local lines = vim.api.nvim_buf_get_lines(0, initial, last, false)
		for i, basename in ipairs(lines) do
			local path = state.cwd .. "/" .. basename
			local line = initial + i - 1

			M.add_yank(line, path, vim.v.register)
		end
		M.render(state)
	end, { buffer = 0 })

	vim.keymap.set("n", "x", function()
		M.set_mode("move")
		vim.api.nvim_set_option("operatorfunc", "v:lua.navi_yank_motion")
		return "g@"
	end, {
		buffer = 0,
		silent = true,
		expr = true,
		noremap = true,
	})

	vim.keymap.set("x", "x", function()
		M.set_mode("move")
		local line_start, _, line_end, _ = get_visual_selection_range()
		local lines =
			vim.api.nvim_buf_get_lines(0, line_start - 1, line_end, false)

		for i, line in ipairs(lines) do
			local yank = {
				line = i + line_start - 2,
				path = state.cwd .. "/" .. line,
			}
			M.add_yank(yank.line, yank.path, vim.v.register)
		end

		M.render(state)
		local keys = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "x", true)
	end, { buffer = 0 })

	vim.keymap.set("n", "xx", function()
		M.set_mode("move")
		local pos = vim.api.nvim_win_get_cursor(0)
		local lines = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)
		local line = lines[1]
		local path = state.cwd .. "/" .. line

		M.add_yank(pos[1] - 1, path, vim.v.register)
		M.render(state)
	end, { buffer = 0 })

	vim.keymap.set("n", "p", function()
		if #vim.tbl_values(M.yanks) == 0 then
			print("nothing to copy nor move")
			return
		end
		local register = vim.v.register

		for line, yank in pairs(M.yanks) do
			if yank.register == register then
				if yank.mode == "copy" then
					copy_file(yank.path, state.cwd)
				end
				if yank.mode == "move" then
					local new = state.cwd .. "/" .. vim.fs.basename(yank.path)
					move_file(yank.path, new)
				end
			end

			M.yanks[line] = nil
		end

		State.set_mode(state, "none")

		vim.defer_fn(function()
			state.files = M.readdir(state.cwd)
			M.render(state)
			State.set_mode(state, "rename")
		end, 50)
	end, { buffer = 0 })

	vim.keymap.set("n", "<Tab><Tab>", function()
		local count = vim.v.count
		local pos = vim.api.nvim_win_get_cursor(0)
		local line = pos[1] - 1

		for i = line, line + count do
			if M.yanks[i] then
				M.yanks[i] = nil
			end
		end

		M.render(state)
	end, { buffer = 0 })

	vim.keymap.set("x", "<Tab>", function()
		local line_start, _, line_end, _ = get_visual_selection_range()

		for i = line_start - 1, line_end - 1 do
			if M.yanks[i] then
				M.yanks[i] = nil
			end
		end

		M.render(state)
		local keys = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)--[[@as string]]
		vim.api.nvim_feedkeys(keys, "x", true)
	end, { buffer = 0 })

	vim.api.nvim_create_autocmd("InsertEnter", {
		buffer = 0,
		callback = function()
			state.inserting = true
		end,
	})

	vim.api.nvim_create_autocmd("InsertLeave", {
		buffer = 0,
		callback = function()
			State.set_mode(state, "none")
			state.inserting = false
			State.apply_changes(state)
		end,
	})
end

return M
