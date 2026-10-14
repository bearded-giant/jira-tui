local config = require("jira_tui.config")
local json = require("jira_tui.json")
local md = require("jira_tui.md")

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
  local pipe = io.popen(M._curl .. " -K " .. q(cfgfile) .. ' 2>/dev/null; echo "__rc=$?"', "r")
  local out = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end

  os.remove(cfgfile)
  if datafile then os.remove(datafile) end

  local body, http, rc = out:match("^(.*)__http=(%d+)__rc=(%d+)%s*$")
  return M.parse_response(body, tonumber(http), tonumber(rc))
end

M._curl = "curl"

function M.parse_response(body, http, rc)
  if not rc or not http then return nil, "curl failed to run" end
  if rc ~= 0 then
    local why = M.CURL_ERRORS[rc]
    return nil, "curl failed (exit " .. rc .. (why and ": " .. why or "") .. ")"
  end

  local result
  if body and body ~= "" then
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

local function slurp(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function cleanup(h)
  for _, k in ipairs({ "cfg", "data", "body", "code", "rc" }) do if h[k] then os.remove(h[k]) end end
  if h.rc then os.remove(h.rc .. ".tmp") end
end

-- background curl. the subshell must not hold the popen pipe (all fds redirected) or the read
-- of $! blocks until curl exits. it removes the -K file (token) itself before rc appears.
function M.request_async(method, endpoint, data)
  local env = config.options.jira
  if env.base == "" or env.email == "" or env.token == "" then return nil, "missing jira config" end
  local h = {}
  if data then
    local derr
    h.data, derr = write_tmp(json.encode(data))
    if not h.data then return nil, derr end
  end
  local cerr
  h.cfg, cerr = write_tmp(table.concat(M._config_lines(env, method, endpoint, h.data), "\n") .. "\n")
  if not h.cfg then cleanup({ data = h.data }); return nil, cerr end
  h.body, h.code, h.rc = h.cfg .. ".body", h.cfg .. ".code", h.cfg .. ".rc"
  local cmd = string.format(
    "umask 077; ( %s -K %s -o %s > %s 2>/dev/null; r=$?; rm -f %s %s; echo $r > %s; mv %s %s ) </dev/null >/dev/null 2>&1 & echo $!",
    M._curl, q(h.cfg), q(h.body), q(h.code), q(h.cfg), q(h.data or ""), q(h.rc .. ".tmp"), q(h.rc .. ".tmp"), q(h.rc))
  local p = io.popen(cmd, "r")
  h.pid = p and tonumber(p:read("*l") or "")
  if p then p:close() end
  if not h.pid then cleanup(h); return nil, "could not start curl" end
  return h
end

-- false while curl runs; then true, result, err (same shape as a blocking request)
function M.poll(h)
  local rc = slurp(h.rc)
  if not rc then return false end
  local body = slurp(h.body) or ""
  local http = (slurp(h.code) or ""):match("__http=(%d+)")
  cleanup(h)
  return true, M.parse_response(body, tonumber(http), tonumber(rc))
end

function M.cancel(h)
  os.execute("pkill -P " .. h.pid .. " >/dev/null 2>&1; kill " .. h.pid .. " >/dev/null 2>&1")
  cleanup(h)
end

-- a request made inside a load coroutine (registered here) runs in the background and yields
-- its handle until done; anywhere else it blocks
M._async = setmetatable({}, { __mode = "k" })
function M.request(method, endpoint, data)
  local co = coroutine.running()
  if not (co and M._async[co]) then return curl_request(method, endpoint, data) end
  local h, err = M.request_async(method, endpoint, data)
  if not h then return nil, err end
  while true do
    local done, res, perr = M.poll(h)
    if done then return res, perr end
    coroutine.yield(h)
  end
end

function M.row_fields(project_key)
  return {
    "summary", "status", "parent", "priority", "assignee", "reporter",
    "created", "updated", "labels", "timespent", "timeoriginalestimate", "issuetype",
    config.get_project_config(project_key).story_point_field,
  }
end

function M.search_issues(jql, page_token, max_results, fields, project_key)
  fields = fields or M.row_fields(project_key)
  return M.request("POST", "/rest/api/3/search/jql", {
    jql = jql,
    fields = fields,
    nextPageToken = page_token or "",
    maxResults = max_results or 100,
  })
end

function M.get_issue(issue_key, fields)
  local qs = fields and ("?fields=" .. table.concat(fields, ",")) or ""
  return M.request("GET", "/rest/api/3/issue/" .. issue_key .. qs, nil)
end

function M.get_transitions(issue_key)
  local result, err = M.request("GET", "/rest/api/3/issue/" .. issue_key .. "/transitions", nil)
  if err or type(result) ~= "table" then return nil, err or "no transitions" end
  return result.transitions or {}, nil
end

function M.transition_issue(issue_key, transition_id)
  return M.request("POST", "/rest/api/3/issue/" .. issue_key .. "/transitions",
    { transition = { id = transition_id } })
end

-- memoized on success only, so a transient failure doesn't stick for the session
M._me = nil
function M.myself()
  if M._me then return M._me end
  local res, err = M.request("GET", "/rest/api/3/myself", nil)
  if err or type(res) ~= "table" or not res.accountId then return nil, err or "cannot resolve current user" end
  M._me = { accountId = res.accountId, displayName = res.displayName }
  return M._me
end

function M.get_comments(issue_key, max)
  local result, err = M.request("GET",
    "/rest/api/3/issue/" .. issue_key .. "/comment?orderBy=-created&maxResults=" .. (max or 20), nil)
  if err or type(result) ~= "table" then return nil, err or "no comments" end
  return result.comments or {}, nil
end

function M.add_comment(issue_key, adf)
  return M.request("POST", "/rest/api/3/issue/" .. issue_key .. "/comment", { body = adf })
end

function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- query searches every assignable user server-side; without it jira returns the first 50
function M.get_assignable(issue_key, query)
  local qs = (query and query ~= "") and ("&query=" .. M.urlencode(query)) or ""
  local result, err = M.request("GET",
    "/rest/api/3/user/assignable/search?issueKey=" .. issue_key .. "&maxResults=50" .. qs, nil)
  if err or type(result) ~= "table" then return nil, err or "no users" end
  return result, nil
end

function M.assign_issue(issue_key, account_id)
  return M.request("PUT", "/rest/api/3/issue/" .. issue_key .. "/assignee", { accountId = account_id })
end

-- append markdown to an existing adf doc (mutates the passed doc's content,
-- which is always a freshly fetched issue here). nil doc -> new doc.
function M.append_to_adf(existing_adf, text)
  local addition = md.to_adf(text)
  if not addition then return existing_adf end
  if type(existing_adf) ~= "table" or type(existing_adf.content) ~= "table" then return addition end
  for _, p in ipairs(addition.content) do
    existing_adf.content[#existing_adf.content + 1] = p
  end
  return existing_adf
end

function M.update_issue(issue_key, fields)
  return M.request("PUT", "/rest/api/3/issue/" .. issue_key, { fields = fields })
end

M._priorities = nil
function M.get_priorities()
  if M._priorities then return M._priorities end
  local res, err = M.request("GET", "/rest/api/3/priority/search", nil)
  if err or type(res) ~= "table" or type(res.values) ~= "table" then return nil, err or "no priorities" end
  M._priorities = res.values
  return res.values
end

M._create_types = {}
function M.get_create_types(project)
  if M._create_types[project] then return M._create_types[project] end
  local res, err = M.request("GET", "/rest/api/3/issue/createmeta/" .. project .. "/issuetypes", nil)
  if err or type(res) ~= "table" or type(res.issueTypes) ~= "table" then return nil, err or "no issue types" end
  M._create_types[project] = res.issueTypes
  return res.issueTypes
end

function M.create_issue(project_key, summary, issue_type, opts)
  opts = opts or {}
  local fields = {
    project = { key = project_key },
    summary = summary,
    issuetype = type(issue_type) == "table" and { id = issue_type.id } or { name = issue_type or "Story" },
  }
  if opts.description and opts.description ~= "" then
    fields.description = md.to_adf(opts.description)
  end
  if opts.assignee_account_id then fields.assignee = { accountId = opts.assignee_account_id } end
  if opts.parent then fields.parent = { key = opts.parent } end
  if opts.labels and #opts.labels > 0 then fields.labels = opts.labels end
  if opts.points then fields[config.get_project_config(project_key).story_point_field] = opts.points end
  if opts.priority then fields.priority = { name = opts.priority } end
  return M.request("POST", "/rest/api/3/issue", { fields = fields })
end

function M.add_worklog(issue_key, time_spent)
  return M.request("POST", "/rest/api/3/issue/" .. issue_key .. "/worklog", { timeSpent = time_spent })
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
