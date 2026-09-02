local api = require("jira_tui.api")
local config = require("jira_tui.config")

local M = {}

local function safe_get(obj, key, subkey)
  if type(obj) ~= "table" then return nil end
  local val = obj[key]
  if subkey then
    if type(val) ~= "table" then return nil end
    return val[subkey]
  end
  return val
end

local function map_issue(issue, story_point_field)
  local fields = issue.fields or {}
  local status_category
  if type(fields.status) == "table" and type(fields.status.statusCategory) == "table" then
    status_category = fields.status.statusCategory.name
  end
  return {
    key = issue.key,
    summary = fields.summary or "",
    status = safe_get(fields, "status", "name") or "Unknown",
    parent = safe_get(fields, "parent", "key"),
    priority = safe_get(fields, "priority", "name") or "None",
    assignee = safe_get(fields, "assignee", "displayName") or "Unassigned",
    assignee_account_id = safe_get(fields, "assignee", "accountId"),
    time_spent = fields.timespent,
    time_estimate = fields.timeoriginalestimate,
    type = safe_get(fields, "issuetype", "name") or "Task",
    reporter = safe_get(fields, "reporter", "displayName") or "Unknown",
    created = fields.created,
    story_points = safe_get(fields, story_point_field),
    status_category = status_category,
  }
end

local function fetch_all(project, jql)
  local p_config = config.get_project_config(project)
  local spf = p_config.story_point_field
  local limit = config.options.jira.limit or 200
  local all = {}
  local page_token = ""

  while true do
    local result, err = api.search_issues(jql, page_token, 100, nil, project)
    if err then return nil, err end
    if type(result) ~= "table" then return all, nil end

    if not result.issues then
      if result.errorMessages and #result.errorMessages > 0 then
        return nil, table.concat(result.errorMessages, "; ")
      elseif result.errors then
        local msgs = {}
        for k, v in pairs(result.errors) do msgs[#msgs + 1] = k .. ": " .. v end
        return nil, table.concat(msgs, "; ")
      end
      return all, nil
    end

    for _, issue in ipairs(result.issues) do
      all[#all + 1] = map_issue(issue, spf)
    end

    if not result.nextPageToken or #all >= limit then
      -- third value: more pages existed but the configured limit cut them off
      return all, nil, (result.nextPageToken and #all >= limit) or nil
    end
    page_token = result.nextPageToken
  end
end

-- every user string that lands inside jql goes through here: an embedded quote
-- otherwise yields invalid jql and a cryptic 400 from jira
function M.jql_quote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

function M.valid_project(key)
  return type(key) == "string" and key:match("^[A-Z][A-Z0-9_]+$") ~= nil
end

local function check_projects(list)
  for _, p in ipairs(list) do
    if not M.valid_project(p) then return nil, "invalid project key: " .. tostring(p) end
  end
  return true
end

local function filter_clause(filter)
  if filter and filter ~= "" then return " AND summary ~ " .. M.jql_quote(filter) end
  return ""
end

function M.sprint_jql(project, filter)
  return "project = " .. project .. " AND sprint in openSprints()" .. filter_clause(filter) .. " ORDER BY Rank ASC"
end

function M.backlog_jql(project, filter)
  return "project = " .. project .. " AND (sprint is EMPTY OR sprint not in openSprints()) AND statusCategory != Done"
    .. filter_clause(filter) .. " ORDER BY Rank ASC"
end

-- build the my-issues jql, optionally scoped to a configured project list
function M.my_issues_jql(projects, filter)
  local jql = "assignee = currentUser() AND statusCategory != Done"
  if projects and #projects > 0 then
    jql = string.format("project in (%s) AND ", table.concat(projects, ", ")) .. jql
  end
  return jql .. filter_clause(filter) .. " ORDER BY updated DESC"
end

-- add a summary filter to an arbitrary user query: wrap the body, keep its ORDER BY last
function M.with_filter(jql, filter)
  if not filter or filter == "" then return jql end
  local body, order = jql:match("^(.-)%s+([Oo][Rr][Dd][Ee][Rr]%s+[Bb][Yy]%s.*)$")
  body = body or jql
  return "(" .. body .. ")" .. filter_clause(filter) .. (order and " " .. order or "")
end

function M.get_active_sprint_issues(project, filter)
  if not project then return nil, "project key required" end
  local ok, err = check_projects({ project })
  if not ok then return nil, err end
  return fetch_all(project, M.sprint_jql(project, filter))
end

function M.get_backlog_issues(project, filter)
  if not project then return nil, "project key required" end
  local ok, err = check_projects({ project })
  if not ok then return nil, err end
  return fetch_all(project, M.backlog_jql(project, filter))
end

function M.get_my_issues(projects, filter)
  local ok, err = check_projects(projects or {})
  if not ok then return nil, err end
  return fetch_all(nil, M.my_issues_jql(projects, filter))
end

-- a bare issue key (REF-372) is not valid jql on its own; rewrite to a key lookup
function M.normalize_jql(jql)
  if not jql then return jql end
  local trimmed = jql:gsub("^%s*(.-)%s*$", "%1")
  if trimmed:match("^%a[%a%d]*%-%d+$") then
    return string.format("key = %s", trimmed:upper())
  end
  return jql
end

function M.get_issues_by_jql(project, jql, filter)
  jql = M.normalize_jql(jql)
  if not jql or jql == "" then return nil, "jql required" end
  return fetch_all(project, M.with_filter(jql, filter))
end

return M
