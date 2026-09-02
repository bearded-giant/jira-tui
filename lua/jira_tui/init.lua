local config = require("jira_tui.config")
local render = require("jira_tui.render")
local sprint = require("jira_tui.sprint")
local state = require("jira_tui.state")
local tui = require("jira_tui.tui")

local M = {}

local function make_loader(default_project, my_projects)
  -- project arg (from the in-TUI prompt) wins; falls back to launch default
  return function(view, filter, project)
    project = project or default_project
    if view == "Backlog" then
      return sprint.get_backlog_issues(project, filter)
    elseif view == "My Issues" then
      return sprint.get_my_issues(my_projects, filter)
    elseif render.jql_query(view) then
      return sprint.get_issues_by_jql(project, render.jql_query(view), filter)
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

keys: j/k move  Enter open  t all  / filter  M mine  p project
      J jql  K detail  b open  x hide-resolved  r refresh  q quit
]])
end

-- argv + persisted last project -> { project, view } or { help = true }.
-- view: explicit flag > project arg (Active Sprint) > My Issues. last_project only
-- seeds S/B inside the tui; it never picks the startup view (README contract).
function M.resolve_launch(argv, last_project)
  local project, view
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "-h" or a == "--help" then return { help = true }
    elseif a == "--backlog" then view = "Backlog"
    elseif a == "--my" then view = "My Issues"
    elseif a == "--jql" then i = i + 1; view = render.jql_view(argv[i] or "")
    elseif a:sub(1, 1) ~= "-" then project = a:upper()
    end
    i = i + 1
  end
  if not view then view = project and "Active Sprint" or "My Issues" end
  return { project = project or last_project, view = view }
end

function M.main(argv)
  state.load()
  local launch = M.resolve_launch(argv, state.data.last_project)
  if launch.help then usage(); return 0 end

  local ok, err = config.load()
  if not ok then io.stderr:write("jira-tui: " .. err .. "\n"); return 1 end

  tui.run({
    load = make_loader(launch.project, config.options.my_issues_projects),
    project = launch.project,
    initial_view = launch.view,
    state = state,
    my_projects = config.options.my_issues_projects,
    hidden_tabs = config.options.hidden_tabs,
  })
  return 0
end

return M
