local M = {}

local FALLBACKS = {
  story_point_field = "customfield_10035",
  acceptance_criteria_field = "customfield_10016",
}

M.options = {
  jira = { base = "", email = "", token = "", limit = 500 },
  projects = {},
}

function M.config_path()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local home = os.getenv("HOME") or ""
  return (xdg and xdg ~= "" and xdg or (home .. "/.config")) .. "/jira-tui/config.lua"
end

-- load ~/.config/jira-tui/config.lua (returns a table), then overlay env vars.
-- env wins so a token can stay out of the dotfile.
function M.load()
  local path = M.config_path()
  local chunk = loadfile(path)
  if chunk then
    local ok, user = pcall(chunk)
    if ok and type(user) == "table" then
      for k, v in pairs(user.jira or {}) do M.options.jira[k] = v end
      M.options.projects = user.projects or {}
    end
  end

  local env = M.options.jira
  env.base = os.getenv("JIRA_BASE") or env.base
  env.email = os.getenv("JIRA_EMAIL") or env.email
  env.token = os.getenv("JIRA_TOKEN") or env.token

  if env.base == "" or env.email == "" or env.token == "" then
    return nil, "missing jira config. set JIRA_BASE/JIRA_EMAIL/JIRA_TOKEN or write " .. path
  end
  -- strip trailing slash so endpoint concat is clean
  env.base = env.base:gsub("/+$", "")
  return true
end

function M.get_project_config(project_key)
  local p = (M.options.projects or {})[project_key] or {}
  return {
    story_point_field = p.story_point_field or FALLBACKS.story_point_field,
    acceptance_criteria_field = p.acceptance_criteria_field or FALLBACKS.acceptance_criteria_field,
  }
end

return M
