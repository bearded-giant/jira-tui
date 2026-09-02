local config = require("jira_tui.config")
local json = require("jira_tui.json")

local M = {}

-- mktemp creates 600 under umask 077 -- the -K file holds email:token
local function write_tmp(content)
  local p = io.popen("umask 077; mktemp 2>/dev/null")
  local path = p and p:read("*l")
  if p then p:close() end
  if not path or path == "" then return nil, "mktemp failed" end
  local f, ferr = io.open(path, "w")
  if not f then os.remove(path); return nil, "cannot write temp file: " .. tostring(ferr) end
  f:write(content)
  f:close()
  return path
end

local function q(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

-- build the curl -K config lines. exposed for testing the quoting.
-- @ must be inside the quotes; curl -K reads `data = "@/path"` as a file ref,
-- whereas `data = @"/path"` makes curl open a file literally named "/path".
function M._config_lines(env, method, endpoint, datafile)
  local lines = {
    "silent",
    -- raw mode disables SIGINT, so a hung connection would freeze the tui with no escape
    "connect-timeout = 5",
    "max-time = 30",
    -- trailing marker so the caller gets the real status (204 vs auth/404/network)
    'write-out = "__http=%{http_code}"',
    "url = " .. q(env.base .. endpoint),
    "user = " .. q(env.email .. ":" .. env.token),
    "request = " .. q(method),
    'header = "Content-Type: application/json"',
    'header = "Accept: application/json"',
  }
  if datafile then
    lines[#lines + 1] = "data = " .. q("@" .. datafile)
  end
  return lines
end

M.CURL_ERRORS = { [6] = "could not resolve host", [7] = "could not connect", [28] = "timed out" }

-- synchronous curl. secrets + body go through a -K config file and a data file
-- so the token never lands in argv/ps and the shell never sees user input.
local function curl_request(method, endpoint, data)
  local env = config.options.jira
  if env.base == "" or env.email == "" or env.token == "" then
    return nil, "missing jira config"
  end

  local datafile, derr
  if data then
    datafile, derr = write_tmp(json.encode(data))
    if not datafile then return nil, derr or "cannot write temp file" end
  end

  local cfgfile, cerr = write_tmp(table.concat(M._config_lines(env, method, endpoint, datafile), "\n") .. "\n")
  if not cfgfile then
    if datafile then os.remove(datafile) end
    return nil, cerr or "cannot write temp file"
  end
  -- luajit's pclose() reports success for any exit code, so echo $? and parse it from the tail
  local pipe = io.popen("curl -K " .. q(cfgfile) .. ' 2>/dev/null; echo "__rc=$?"', "r")
  local out = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end

  os.remove(cfgfile)
  if datafile then os.remove(datafile) end

  local body, http, rc = out:match("^(.*)__http=(%d+)__rc=(%d+)%s*$")
  rc, http = tonumber(rc), tonumber(http)
  if not rc then return nil, "curl failed to run" end
  if rc ~= 0 then
    local why = M.CURL_ERRORS[rc]
    return nil, "curl failed (exit " .. rc .. (why and ": " .. why or "") .. ")"
  end

  local result
  if body ~= "" then
    local ok, parsed = pcall(json.decode, body)
    if not ok then
      return nil, "failed to parse json: " .. tostring(parsed) .. " | resp: " .. body:sub(1, 200)
    end
    result = parsed
  end

  if http >= 400 then
    local msg
    if type(result) == "table" then
      if type(result.errorMessages) == "table" and #result.errorMessages > 0 then
        msg = table.concat(result.errorMessages, "; ")
      elseif type(result.errors) == "table" then
        local parts = {}
        for k, v in pairs(result.errors) do parts[#parts + 1] = k .. ": " .. tostring(v) end
        msg = table.concat(parts, "; ")
      end
    end
    return nil, "HTTP " .. http .. (msg and msg ~= "" and (": " .. msg) or " from jira")
  end
  if result == nil then return true, nil end -- 2xx, no body (204 on mutations)
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

function M.get_comments(issue_key, max)
  local result, err = curl_request("GET",
    "/rest/api/3/issue/" .. issue_key .. "/comment?orderBy=-created&maxResults=" .. (max or 20), nil)
  if err or type(result) ~= "table" then return nil, err or "no comments" end
  return result.comments or {}, nil
end

function M.get_assignable(issue_key)
  local result, err = curl_request("GET",
    "/rest/api/3/user/assignable/search?issueKey=" .. issue_key .. "&maxResults=50", nil)
  if err or type(result) ~= "table" then return nil, err or "no users" end
  return result, nil
end

function M.assign_issue(issue_key, account_id)
  return curl_request("PUT", "/rest/api/3/issue/" .. issue_key .. "/assignee", { accountId = account_id })
end

-- plain text -> adf doc. blank lines become empty paragraphs (json.encode
-- emits [] for empty tables, which is what jira expects for content).
function M.text_to_adf(text)
  if not text or text == "" then return nil end
  local paragraphs = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line == "" then
      paragraphs[#paragraphs + 1] = { type = "paragraph", content = {} }
    else
      paragraphs[#paragraphs + 1] = { type = "paragraph", content = { { type = "text", text = line } } }
    end
  end
  return { type = "doc", version = 1, content = paragraphs }
end

-- append plain text to an existing adf doc (mutates the passed doc's content,
-- which is always a freshly fetched issue here). nil doc -> new doc.
function M.append_to_adf(existing_adf, text)
  local addition = M.text_to_adf(text)
  if not addition then return existing_adf end
  if type(existing_adf) ~= "table" or type(existing_adf.content) ~= "table" then return addition end
  for _, p in ipairs(addition.content) do
    existing_adf.content[#existing_adf.content + 1] = p
  end
  return existing_adf
end

function M.update_issue(issue_key, fields)
  return curl_request("PUT", "/rest/api/3/issue/" .. issue_key, { fields = fields })
end

function M.create_issue(project_key, summary, issue_type, opts)
  opts = opts or {}
  local fields = {
    project = { key = project_key },
    summary = summary,
    issuetype = { name = issue_type or "Story" },
  }
  if opts.description and opts.description ~= "" then
    fields.description = M.text_to_adf(opts.description)
  end
  if opts.assignee_account_id then
    fields.assignee = { accountId = opts.assignee_account_id }
  end
  return curl_request("POST", "/rest/api/3/issue", { fields = fields })
end

function M.add_worklog(issue_key, time_spent)
  return curl_request("POST", "/rest/api/3/issue/" .. issue_key .. "/worklog", { timeSpent = time_spent })
end

-- download one attachment to a temp dir, return the local path.
-- jira 303s to a signed media url; curl drops the auth header on the
-- cross-host redirect, which is exactly what the media host expects.
function M.download_attachment(att)
  local env = config.options.jira
  if env.base == "" or env.email == "" or env.token == "" then return nil, "missing jira config" end
  local url = att.content or (env.base .. "/rest/api/3/attachment/content/" .. tostring(att.id or ""))
  local name = tostring(att.filename or "attachment"):gsub("[^%w%.%- _]", "_")
  local dir = ((os.getenv("TMPDIR") or "/tmp"):gsub("/$", "")) .. "/jira-tui"
  os.execute("mkdir -p " .. q(dir) .. " >/dev/null 2>&1")
  local dest = dir .. "/" .. name
  local lines = {
    "silent", "location", "connect-timeout = 5", "max-time = 60",
    'write-out = "__http=%{http_code}"',
    "url = " .. q(url),
    "user = " .. q(env.email .. ":" .. env.token),
    "output = " .. q(dest),
  }
  local cfgfile, cerr = write_tmp(table.concat(lines, "\n") .. "\n")
  if not cfgfile then return nil, cerr or "cannot write temp file" end
  local pipe = io.popen("curl -K " .. q(cfgfile) .. ' 2>/dev/null; echo "__rc=$?"', "r")
  local out = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  os.remove(cfgfile)
  local http, rc = out:match("__http=(%d+)__rc=(%d+)%s*$")
  rc, http = tonumber(rc), tonumber(http)
  if not rc then return nil, "curl failed to run" end
  if rc ~= 0 then
    local why = M.CURL_ERRORS[rc]
    return nil, "curl failed (exit " .. rc .. (why and ": " .. why or "") .. ")"
  end
  if http ~= 200 then return nil, "http " .. tostring(http) end
  return dest
end

return M
