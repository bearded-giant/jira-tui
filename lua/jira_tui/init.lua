local config = require("jira_tui.config")
local sprint = require("jira_tui.sprint")
local tui = require("jira_tui.tui")

local M = {}

local function make_loader(project)
  return function(view, filter)
    if view == "Backlog" then
      return sprint.get_backlog_issues(project, filter)
    elseif view == "My Issues" then
      local jql = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
      return sprint.get_issues_by_jql(nil, jql)
    elseif view:sub(1, 4) == "JQL:" then
      return sprint.get_issues_by_jql(project, view:sub(5))
    else -- Active Sprint
      return sprint.get_active_sprint_issues(project, filter)
    end
  end
end

local function usage()
  io.stderr:write([[
jira-tui — standalone terminal UI for Jira

usage: jira-tui [PROJECT_KEY] [--backlog | --my | --jql "<jql>"]

config: ]] .. config.config_path() .. [[ (lua table) or env
  JIRA_BASE   https://your-domain.atlassian.net
  JIRA_EMAIL  you@example.com
  JIRA_TOKEN  api token

keys: j/k move  o expand  t all  r refresh  S sprint  B backlog
      J jql  / filter  K detail  x open  q quit
]])
end

function M.main(argv)
  local project, view, jql
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "-h" or a == "--help" then usage(); return 0
    elseif a == "--backlog" then view = "Backlog"
    elseif a == "--my" then view = "My Issues"
    elseif a == "--jql" then i = i + 1; jql = argv[i]; view = "JQL:" .. (jql or "")
    elseif a:sub(1, 1) ~= "-" then project = a
    end
    i = i + 1
  end

  local ok, err = config.load()
  if not ok then io.stderr:write("jira-tui: " .. err .. "\n"); return 1 end

  if not project and not jql and view ~= "My Issues" then
    io.stderr:write("jira-tui: need a PROJECT_KEY (or --my / --jql)\n\n")
    usage()
    return 1
  end

  tui.run({
    load = make_loader(project),
    project = project,
    initial_view = view or "Active Sprint",
  })
  return 0
end

return M
