local config = require("jira_tui.config")
local sprint = require("jira_tui.sprint")
local state = require("jira_tui.state")
local tui = require("jira_tui.tui")

local M = {}

local function make_loader(project, my_projects)
  return function(view, filter)
    if view == "Backlog" then
      return sprint.get_backlog_issues(project, filter)
    elseif view == "My Issues" then
      return sprint.get_my_issues(my_projects, filter)
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

  no args -> opens My Issues (no project required).
  PROJECT_KEY -> opens that project's active sprint.

config: ]] .. config.config_path() .. [[ (lua table) or env
  JIRA_BASE   https://your-domain.atlassian.net
  JIRA_EMAIL  you@example.com
  JIRA_TOKEN  api token (JIRA_API_TOKEN also accepted)

keys: j/k move  o expand  t all  M my-issues  p set-project
      S sprint  B backlog  J jql (history)  / filter  r refresh
      K detail  x open  q quit
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

  state.load()

  -- project defaults to last-used so Sprint/Backlog have a target
  project = project or state.data.last_project

  -- view: explicit flag > project arg > restored last_view > My Issues
  if not view then
    if project and state.data.last_view == "Active Sprint" then
      view = "Active Sprint"
    elseif project and state.data.last_view == "Backlog" then
      view = "Backlog"
    else
      view = "My Issues"
    end
  end

  tui.run({
    load = make_loader(project, config.options.my_issues_projects),
    project = project,
    initial_view = view,
    state = state,
  })
  return 0
end

return M
