local json = require("jira_tui.json")

local M = {}

M.data = { jql_history = {}, my_issues_projects = {} }

local HISTORY_CAP = 50

local function home() return os.getenv("HOME") or "" end

local function tui_path()
  local xdg = os.getenv("XDG_DATA_HOME")
  return (xdg and xdg ~= "" and xdg or (home() .. "/.local/share")) .. "/jira-tui/state.json"
end

local function jim_path()
  return home() .. "/.local/share/nvim/jim_nvim.json"
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

-- load tui state, then backfill missing lists from jim.nvim's state so an
-- existing nvim setup carries over its projects + jql history.
function M.load()
  local own = read_json(tui_path())
  if own then
    M.data.jql_history = own.jql_history or {}
    M.data.my_issues_projects = own.my_issues_projects or {}
  end

  if #M.data.jql_history == 0 or #M.data.my_issues_projects == 0 then
    local jim = read_json(jim_path())
    if jim then
      if #M.data.jql_history == 0 then M.data.jql_history = jim.jql_history or {} end
      if #M.data.my_issues_projects == 0 then
        M.data.my_issues_projects = jim.my_issues_projects or {}
      end
    end
  end
  return M.data
end

function M.save()
  local path = tui_path()
  os.execute(string.format("mkdir -p %q 2>/dev/null", path:match("(.*)/")))
  local f = io.open(path, "w")
  if not f then return end
  f:write(json.encode(M.data))
  f:close()
end

-- prepend, dedupe, cap. returns nothing; persists.
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
