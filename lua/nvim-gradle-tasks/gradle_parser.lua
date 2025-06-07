-- gradle_parser.lua
local M = {}

function M.parse_gradle_tasks_output(lines)
  local gradle_tasks = {}
  local gradle_task_descriptions = {}
  local gradle_task_groups = {}
  local gradle_task_group_order = {}
  local current_group = nil
  local parsing_groups = false
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- Suche nach Gruppen-Header: alles ab der ersten langen ("----") Linie
    if not parsing_groups then
      if line:match("^%-+$") then
        parsing_groups = true
      end
    elseif line:match("^%s*$") then
      -- skip empty
    elseif line:match("^%-+$") then
      -- skip group separator
    elseif lines[i+1] and lines[i+1]:match("^%-+$") and not line:match(":") then
      -- Diese Zeile ist Group-Header (z.B. Build tasks)
      current_group = line
      if not vim.tbl_contains(gradle_task_group_order, current_group) then
        table.insert(gradle_task_group_order, current_group)
      end
      -- Skip nächstes (Trenn-)Zeichen
      i = i + 1
    else
      -- Taskzeile: <task> - <desc> ODER <task>
      local clean = line:gsub("^%s*[|%s]*", "")
      local task, desc = string.match(clean, "^([%w_:%.%-]+)%s+%-%s?(.*)$")
      if not task then
        task = clean:match("^([%w_:%.%-]+)$")
        desc = ""
      end
      if task then
        gradle_tasks[task] = true
        gradle_task_descriptions[task] = desc
        gradle_task_groups[task] = current_group or "Other"
      end
    end
    i = i + 1
  end
  return gradle_tasks, gradle_task_descriptions, gradle_task_groups, gradle_task_group_order
end

return M
