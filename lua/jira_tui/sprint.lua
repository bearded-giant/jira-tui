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
      return all, nil
    end
    page_token = result.nextPageToken
  end
end

function M.get_active_sprint_issues(project, filter)
  if not project then return nil, "project key required" end
  local jql = string.format("project = '%s' AND sprint in openSprints()", project)
  if filter and filter ~= "" then
    jql = jql .. string.format(' AND summary ~ "%s"', filter)
  end
  return fetch_all(project, jql .. " ORDER BY Rank ASC")
end

function M.get_backlog_issues(project, filter)
  if not project then return nil, "project key required" end
  local jql = string.format(
    "project = '%s' AND (sprint is EMPTY OR sprint not in openSprints()) AND statusCategory != Done",
    project)
  if filter and filter ~= "" then
    jql = jql .. string.format(' AND summary ~ "%s"', filter)
  end
  return fetch_all(project, jql .. " ORDER BY Rank ASC")
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

function M.get_issues_by_jql(project, jql)
  jql = M.normalize_jql(jql)
  if not jql or jql == "" then return nil, "jql required" end
  return fetch_all(project, jql)
end

return M
