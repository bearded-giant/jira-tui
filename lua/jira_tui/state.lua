local json = require("jira_tui.json")

local M = {}

M.data = { jql_history = {}, last_view = nil, last_project = nil, hide_resolved = true }

local HISTORY_CAP = 50

function M.state_path()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local home = os.getenv("HOME") or ""
  return (xdg and xdg ~= "" and xdg or (home .. "/.config")) .. "/jira-tui/state.json"
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  local ok, t = pcall(json.decode, body or "")
  if ok and type(t) == "table" then return t end
  return nil
end

function M.load()
  local own = read_json(M.state_path())
  if own then
    M.data.jql_history = own.jql_history or {}
    M.data.last_view = own.last_view
    M.data.last_project = own.last_project
    if own.hide_resolved ~= nil then M.data.hide_resolved = own.hide_resolved end
  end
  return M.data
end

function M.save()
  local path = M.state_path()
  os.execute(string.format("mkdir -p %q 2>/dev/null", path:match("(.*)/")))
  local f = io.open(path, "w")
  if not f then return end
  f:write(json.encode(M.data))
  f:close()
end

function M.remember(view, project)
  M.data.last_view = view
  if project then M.data.last_project = project end
  M.save()
end

-- prepend, dedupe, cap. persists.
function M.add_jql(q)
  if not q or q == "" then return end
  local hist = M.data.jql_history
  for i = #hist, 1, -1 do
    if hist[i] == q then table.remove(hist, i) end
  end
  table.insert(hist, 1, q)
  while #hist > HISTORY_CAP do table.remove(hist) end
  M.save()
end

return M
