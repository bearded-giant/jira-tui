local config = require("jira_tui.config")
local json = require("jira_tui.json")

local M = {}

local function write_tmp(content)
  local path = os.tmpname()
  -- lock perms before the secret lands -- the -K file holds email:token
  io.open(path, "w"):close()
  os.execute(string.format("chmod 600 %q 2>/dev/null", path))
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local function q(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

-- synchronous curl. secrets + body go through a -K config file and a data file
-- so the token never lands in argv/ps and the shell never sees user input.
local function curl_request(method, endpoint, data)
  local env = config.options.jira
  if env.base == "" or env.email == "" or env.token == "" then
    return nil, "missing jira config"
  end

  local lines = {
    "silent",
    "url = " .. q(env.base .. endpoint),
    "user = " .. q(env.email .. ":" .. env.token),
    "request = " .. q(method),
    'header = "Content-Type: application/json"',
    'header = "Accept: application/json"',
  }

  local datafile
  if data then
    datafile = write_tmp(json.encode(data))
    lines[#lines + 1] = "data = @" .. q(datafile)
  end

  local cfgfile = write_tmp(table.concat(lines, "\n") .. "\n")
  local pipe = io.popen("curl -K " .. q(cfgfile) .. " 2>/dev/null", "r")
  local body = pipe and pipe:read("*a") or ""
  local ok_close = pipe and pipe:close()

  os.remove(cfgfile)
  if datafile then os.remove(datafile) end

  if not ok_close then
    return nil, "curl failed"
  end
  if body == "" then
    -- empty is valid only for mutations (204). empty on a read = network/auth fail.
    local is_mutation = method == "PUT"
      or endpoint:find("/transitions") or endpoint:find("/worklog")
    if is_mutation then return true, nil end
    return nil, "empty response from jira (network, auth, or host?)"
  end

  local ok, result = pcall(json.decode, body)
  if not ok then
    return nil, "failed to parse json: " .. tostring(result) .. " | resp: " .. body:sub(1, 200)
  end
  return result, nil
end

M.request = curl_request

function M.search_issues(jql, page_token, max_results, fields, project_key)
  local p_config = config.get_project_config(project_key)
  fields = fields or {
    "summary", "status", "parent", "priority", "assignee", "reporter",
    "created", "timespent", "timeoriginalestimate", "issuetype",
    p_config.story_point_field,
  }
  return curl_request("POST", "/rest/api/3/search/jql", {
    jql = jql,
    fields = fields,
    nextPageToken = page_token or "",
    maxResults = max_results or 100,
  })
end

function M.get_issue(issue_key)
  return curl_request("GET", "/rest/api/3/issue/" .. issue_key, nil)
end

function M.get_transitions(issue_key)
  local result, err = curl_request("GET", "/rest/api/3/issue/" .. issue_key .. "/transitions", nil)
  if err or type(result) ~= "table" then return nil, err or "no transitions" end
  return result.transitions or {}, nil
end

function M.transition_issue(issue_key, transition_id)
  return curl_request("POST", "/rest/api/3/issue/" .. issue_key .. "/transitions",
    { transition = { id = transition_id } })
end

function M.get_myself()
  return curl_request("GET", "/rest/api/3/myself", nil)
end

return M
