-- gradle_tasks.lua
local parser = require("nvim-gradle-tasks.gradle_parser")

local M = {}
local gradle_tasks, gradle_task_descriptions, gradle_task_groups, gradle_task_group_order = {}, {}, {}, {}
local last_gradle_root = nil
local loading = false
M.last_output = {}

local function has_gradle()
  return vim.fn.executable("gradle") == 1
end

-- async recursive search for build.gradle or build.gradle.kts upwards
local function find_gradle_file_upwards_async(start_dir, callback)
  local function scan_dir(dir)
    vim.loop.fs_scandir(dir, function(err, handle)
      if err or not handle then
        callback(nil)
        return
      end
      while true do
        local name = vim.loop.fs_scandir_next(handle)
        if not name then break end
        if name == "build.gradle" or name == "build.gradle.kts" then
          -- found!
          callback(dir)
          return
        end
      end
      -- Not found, check parent dir
      local parent = vim.fn.fnamemodify(dir, ":h")
      if parent == dir or parent == "" or parent == "/" or parent:match("^%a:[/\\]?$") then
        -- reached top
        callback(nil)
      else
        -- recurse parent
        scan_dir(parent)
      end
    end)
  end
  scan_dir(start_dir)
end

-- Asynchronous task loading using vim.system or vim.loop
function M.load_tasks_async(callback)
  if loading then return end
  if not has_gradle() then
    gradle_tasks, gradle_task_descriptions, gradle_task_groups, gradle_task_group_order = {},{},{},{}
    if callback then callback() end
    return
  end
  loading = true
  vim.schedule(function()
    vim.notify("Loading Gradle tasks ...", vim.log.levels.INFO)
  end)
  local function finalize(lines)
    gradle_tasks, gradle_task_descriptions, gradle_task_groups, gradle_task_group_order =
    parser.parse_gradle_tasks_output(lines)
    loading = false
    if callback then
      callback()
    else
      vim.schedule(function()
	vim.notify("Gradle tasks loaded.", vim.log.levels.INFO)
      end)
    end
  end

  if vim.system then
    vim.system({'gradle', 'tasks', '--all', '--console=plain'}, {text=true}, function(res)
      local lines = {}
      if res.stdout then
	for l in res.stdout:gmatch("[^\r\n]+") do table.insert(lines, l) end
      end
      finalize(lines)
    end)
  else
    -- Fallback for Neovim < 0.10
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)
    local output = {}
    local handle
    handle = vim.loop.spawn("gradle", {
      args = {"tasks", "--all", "--console=plain"},
      stdio = {nil, stdout, stderr},
    }, function()
      stdout:close()
      stderr:close()
      handle:close()
      finalize(output)
    end)
    stdout:read_start(function(err, data)
      assert(not err, err)
      if data then
	for l in data:gmatch("[^\r\n]+") do
	  table.insert(output, l)
	end
      end
    end)
    stderr:read_start(function(err, data) end)
  end
end

function M.run_task(task)
  if loading then
    vim.notify("Gradle tasks are still loading, please wait ...", vim.log.levels.WARN)
    return
  end
  if not has_gradle() then
    vim.notify("Gradle is not available!", vim.log.levels.ERROR)
    return
  end
  if not gradle_tasks[task] then
    vim.notify("Task '"..task.."' not found!", vim.log.levels.WARN)
    return
  end
  vim.notify("Running gradle " .. task .. " ...")
  M.last_output = {}
  if vim.system then
    vim.system({"gradle", task}, {text = true}, function(obj)
      local lines = {}
      if obj.stdout then
	for l in obj.stdout:gmatch("[^\r\n]+") do
	  table.insert(lines, l)
	end
      end
      if obj.stderr and #obj.stderr > 0 then
	vim.schedule(function()
	  vim.notify("Gradle error:\n" .. obj.stderr, vim.log.levels.ERROR)
	end)
      end
      M.last_output = lines
      local last = lines[#lines] or "(No output)"
      vim.schedule(function()
	vim.api.nvim_echo({{last, ""}}, false, {})
      end)
    end)
  else
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)
    local output = {}
    local erroutput = {}
    local handle
    handle = vim.loop.spawn("gradle", {
      args = { task },
      stdio = {nil, stdout, stderr},
    },
    function()
      stdout:close()
      stderr:close()
      handle:close()
      M.last_output = output
      vim.schedule(function()
	if #erroutput > 0 then
	  vim.notify("Gradle error:\n" .. table.concat(erroutput, "\n"), vim.log.levels.ERROR)
	end
	local last = output[#output] or "(No output)"
	vim.api.nvim_echo({{last, ""}}, false, {})
      end)
    end)
    stdout:read_start(function(err, data)
      assert(not err, err)
      if data then
	for l in data:gmatch("[^\r\n]+") do
	  table.insert(output, l)
	end
      end
    end)
    stderr:read_start(function(err, data)
      assert(not err, err)
      if data then
	for l in data:gmatch("[^\r\n]+") do
	  table.insert(erroutput, l)
	end
      end
    end)
  end
end

function M.list_tasks()
  if not has_gradle() then
    vim.notify("Gradle is not available!", vim.log.levels.ERROR)
    return
  end
  if loading then
    vim.notify("Gradle tasks are still loading ...", vim.log.levels.INFO)
    return
  end
  -- Gruppiert nach Gradle-Gruppen
  local group_map = {}
  for name, _ in pairs(gradle_tasks) do
    local group = gradle_task_groups[name] or "Other"
    if not group_map[group] then group_map[group] = {} end
    local desc = gradle_task_descriptions[name]
    if desc and #desc > 0 then
      table.insert(group_map[group], name .. " -- " .. desc)
    else
      table.insert(group_map[group], name)
    end
  end
  local items = {}
  for _, group in ipairs(gradle_task_group_order) do
    table.insert(items, "=== " .. group .. " ===")
    if group_map[group] then
      for _, line in ipairs(group_map[group]) do
	table.insert(items, "  " .. line)
      end
    end
    table.insert(items, "") -- Leerzeile zwischen Gruppen
  end
  vim.fn.setqflist({}, ' ', { title = 'Gradle Tasks', lines = items })
  vim.cmd('copen')
end

-- Show full output of last gradle task in new buffer
function M.show_output()
  if not M.last_output or #M.last_output == 0 then
    vim.notify("No gradle task output available.", vim.log.levels.INFO)
    return
  end
  -- Open vertical split, create and display a scratch buffer
  vim.cmd("vsplit")
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.last_output)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'gradle')
  vim.api.nvim_buf_set_name(buf, "Gradle Output")
end

local function gradle_complete(arglead, cmdline, cursorpos)
  local res = {}
  if loading then
    return res
  end
  for name, _ in pairs(gradle_tasks) do
    if name:find(arglead, 1, true) == 1 then
      table.insert(res, name)
    end
  end
  return res
end

vim.api.nvim_create_user_command(
  "Gradle",
  function(opts)
    M.run_task(opts.args)
  end,
  { nargs = 1, complete = gradle_complete }
)

vim.api.nvim_create_user_command(
  "GradleListTasks",
  function()
    M.list_tasks()
  end,
  { nargs = 0 }
)

vim.api.nvim_create_user_command(
  "GradleReloadTasks",
  function()
    M.load_tasks_async(function()
      vim.notify("Gradle tasks reloaded.", vim.log.levels.INFO)
    end)
  end,
  { nargs = 0 }
)

vim.api.nvim_create_user_command(
  "GradleShowOutput",
  function()
    M.show_output()
  end,
  { nargs = 0 }
)

vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
  callback = function()
    local start_dir = vim.loop.cwd()
    vim.defer_fn(function()
      find_gradle_file_upwards_async(start_dir, function(found_dir)
        if found_dir and found_dir ~= last_gradle_root then
          last_gradle_root = found_dir
          M.load_tasks_async()
        end
      end)
    end, 3000)
  end,
})

return M
